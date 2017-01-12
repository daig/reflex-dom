{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE PatternSynonyms #-}
module Reflex.Dom.Main where

import Prelude hiding (concat, mapM, mapM_, sequence, sequence_)

import qualified Reflex as R
import Reflex.Dom.Builder.Immediate
import Reflex.Dom.Class
import Reflex.Host.Class
import Reflex.PerformEvent.Base
import Reflex.PostBuild.Base
import Reflex.Spider (Global, Spider, SpiderHost, runSpiderHost)
import Reflex.TriggerEvent.Base

import Control.Concurrent
import Control.Lens
import Control.Monad
import Control.Monad.Reader hiding (forM, forM_, mapM, mapM_, sequence, sequence_)
import Control.Monad.Ref
import Data.ByteString (ByteString)
import Data.Dependent.Sum (DSum (..))
import Data.IORef
import Data.Maybe
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding
import GHCJS.DOM
import GHCJS.DOM.Document
import GHCJS.DOM.Element
import GHCJS.DOM.Node
import qualified GHCJS.DOM.Types as DOM
import GHCJS.DOM.Types (MonadJSM(..), JSM)

{-# INLINABLE mainWidget #-}
mainWidget :: (forall x. Widget x ()) -> JSM ()
mainWidget w = withJSContextSingleton $ \jsSing -> do
  doc <- currentDocumentUnchecked
  body <- getBodyUnchecked doc
  attachWidget body jsSing w
  forever $ do
    liftIO $ threadDelay 100000
    syncPoint

--TODO: The x's should be unified here
{-# INLINABLE mainWidgetWithHead #-}
mainWidgetWithHead :: (forall x. Widget x ()) -> (forall x. Widget x ()) -> JSM ()
mainWidgetWithHead h b = withJSContextSingleton $ \jsSing -> do
  doc <- currentDocumentUnchecked
  headElement <- getHeadUnchecked doc
  attachWidget headElement jsSing h
  body <- getBodyUnchecked doc
  attachWidget body jsSing b
  forever $ do
    liftIO $ threadDelay 100000
    syncPoint

{-# INLINABLE mainWidgetWithCss #-}
mainWidgetWithCss :: ByteString -> (forall x. Widget x ()) -> JSM ()
mainWidgetWithCss css w = withJSContextSingleton $ \jsSing -> do
  doc <- currentDocumentUnchecked
  headElement <- getHeadUnchecked doc
  setInnerHTML headElement . Just $ "<style>" <> T.unpack (decodeUtf8 css) <> "</style>" --TODO: Fix this
  body <- getBodyUnchecked doc
  attachWidget body jsSing w
  forever $ do
    liftIO $ threadDelay 100000
    syncPoint

type Widget x = PostBuildT Spider (ImmediateDomBuilderT Spider (WithJSContextSingleton x (PerformEventT Spider (SpiderHost Global)))) --TODO: Make this more abstract --TODO: Put the WithJSContext underneath PerformEventT - I think this would perform better

#ifndef __GHCJS__
instance MonadJSM m => MonadJSM (PostBuildT t m) where
    liftJSM' = PostBuildT . liftJSM'
#endif

{-# INLINABLE attachWidget #-}
attachWidget :: DOM.IsElement e => e -> JSContextSingleton x -> Widget x a -> JSM a
attachWidget rootElement wv w = liftIO $ fst <$> attachWidget' rootElement wv w

mainWidgetWithHead' :: (forall x. (a -> Widget x b, b -> Widget x a)) -> JSM ()
mainWidgetWithHead' widgets = withJSContextSingleton $ \jsSing -> do
 doc <- currentDocumentUnchecked
 headElement <- getHeadUnchecked doc
 bodyElement <- getBodyUnchecked doc
--    runWebGUI $ \webView -> withWebViewSingleton webView $ \wv ->
 liftIO $ fmap fst $ attachWidget'' $ \events -> do
  let (headWidget, bodyWidget) = widgets
  (postBuild, postBuildTriggerRef) <- newEventWithTriggerRef
  rec b <- unsafeReplaceElementContentsWithWidget events postBuild headElement jsSing $ headWidget a
      a <- unsafeReplaceElementContentsWithWidget events postBuild bodyElement jsSing $ bodyWidget b
  return ((), postBuildTriggerRef)

unsafeReplaceElementContentsWithWidget :: DOM.IsElement e => EventChannel -> R.Event Spider () -> e -> JSContextSingleton x -> Widget x a -> PerformEventT Spider (SpiderHost Global) a
unsafeReplaceElementContentsWithWidget events postBuild rootElement jsSing w = (`runWithJSContextSingleton` jsSing) $ do
  doc <- getOwnerDocumentUnchecked rootElement
  df <- createDocumentFragmentUnchecked doc
  let builderEnv = ImmediateDomBuilderEnv
        { _immediateDomBuilderEnv_document = doc
        , _immediateDomBuilderEnv_parent = toNode df
        , _immediateDomBuilderEnv_events = events
        }
  result <- runImmediateDomBuilderT (runPostBuildT w postBuild) builderEnv
  setInnerHTML rootElement $ Just ("" :: String)
  _ <- appendChildUnchecked rootElement $ Just df
  return result

{-# INLINABLE attachWidget' #-}
attachWidget' :: DOM.IsElement e => e -> JSContextSingleton x -> Widget x a -> IO (a, FireCommand Spider (SpiderHost Global))
attachWidget' rootElement jsSing w = attachWidget'' $ \events -> do
  (postBuild, postBuildTriggerRef) <- newEventWithTriggerRef
  result <- unsafeReplaceElementContentsWithWidget events postBuild rootElement jsSing w
  return (result, postBuildTriggerRef)

type EventChannel = Chan [DSum (TriggerRef Spider) TriggerInvocation]

{-# INLINABLE attachWidget'' #-}
attachWidget'' :: (EventChannel -> PerformEventT Spider (SpiderHost Global) (a, IORef (Maybe (EventTrigger Spider ())))) -> IO (a, FireCommand Spider (SpiderHost Global))
attachWidget'' w = do
  events <- newChan
  (result, fc@(FireCommand fire)) <- runSpiderHost $ do
    ((result, postBuildTriggerRef), fc@(FireCommand fire)) <- hostPerformEventT $ w events
    mPostBuildTrigger <- readRef postBuildTriggerRef
    forM_ mPostBuildTrigger $ \postBuildTrigger -> fire [postBuildTrigger :=> Identity ()] $ return ()
    return (result, fc)
  void $ forkIO $ forever $ do
    ers <- readChan events
    _ <- runSpiderHost $ do
      mes <- liftIO $ forM ers $ \(TriggerRef er :=> TriggerInvocation a _) -> do
        me <- readIORef er
        return $ fmap (\e -> e :=> Identity a) me
      _ <- fire (catMaybes mes) $ return ()
      liftIO $ forM_ ers $ \(_ :=> TriggerInvocation _ cb) -> cb
    return ()
  return (result, fc)

-- | Run a reflex-dom application inside of an existing DOM element with the given ID
mainWidgetInElementById :: Text -> (forall x. Widget x ()) -> JSM ()
mainWidgetInElementById eid w = withJSContextSingleton $ \jsSing -> do
  doc <- currentDocumentUnchecked
  root <- getElementByIdUnchecked doc eid
  attachWidget root jsSing w
  forever $ do
    liftIO $ threadDelay 100000
    syncPoint

data AppInput t = AppInput
  { _appInput_window :: Window t
  }

data AppOutput t = AppOutput --TODO: Add quit event
  { _appOutput_windowConfig :: WindowConfig t
  }

runApp' :: (t ~ Spider) => (forall x. AppInput t -> Widget x (AppOutput t)) -> JSM ()
runApp' app = withJSContextSingleton $ \jsSing -> do
  doc <- currentDocumentUnchecked
  body <- getBodyUnchecked doc
  win <- getDefaultViewUnchecked doc
  rec o <- attachWidget body jsSing $ do
        w <- lift $ wrapWindow win $ _appOutput_windowConfig o
        app $ AppInput
          { _appInput_window = w
          }
  forever $ do
    liftIO $ threadDelay 100000
    syncPoint