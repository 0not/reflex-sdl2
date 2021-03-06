{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
-- | This module contains the bare minimum needed to get started writing
-- reflex apps using sdl2.
--
-- For an example see
-- [app/Main.hs](https://github.com/schell/reflex-sdl2/blob/master/app/Main.hs)
module Reflex.SDL2
  ( -- * Events
    getDeltaTickEvent
  , getRecurringTimerEvent
  , getAsyncEvent
  , getTicksEvent
  , getAnySDLEvent
  , getWindowShownEvent
  , getWindowHiddenEvent
  , getWindowExposedEvent
  , getWindowMovedEvent
  , getWindowResizedEvent
  , getWindowSizeChangedEvent
  , getWindowMinimizedEvent
  , getWindowMaximizedEvent
  , getWindowRestoredEvent
  , getWindowGainedMouseFocusEvent
  , getWindowLostMouseFocusEvent
  , getWindowGainedKeyboardFocusEvent
  , getWindowLostKeyboardFocusEvent
  , getWindowClosedEvent
  , getKeyboardEvent
  , getTextEditingEvent
  , getTextInputEvent
  , getKeymapChangedEvent
  , getMouseMotionEvent
  , getMouseButtonEvent
  , getMouseWheelEvent
  , getJoyAxisEvent
  , getJoyBallEvent
  , getJoyHatEvent
  , getJoyButtonEvent
  , getJoyDeviceEvent
  , getControllerAxisEvent
  , getControllerButtonEvent
  , getControllerDeviceEvent
  , getAudioDeviceEvent
  , getQuitEvent
  , getUserEvent
  , getSysWMEvent
  , getTouchFingerEvent
  , getMultiGestureEvent
  , getDollarGestureEvent
  , getDropEvent
  , getClipboardUpdateEvent
  , getUnknownEvent
  , getUserData
    -- * Debugging
  , putDebugLnE
    -- * Constraints and the reflex-sdl2 base type
  , ReflexSDL2
  , ReflexSDL2T
  , ConcreteReflexSDL2
    -- * Higher order switching
  , holdView
  , dynView
    -- * Running an app
  , host
    -- * Re-exports
  , module Reflex
  , module SDL
  , MonadIO
  , liftIO
  ) where

import           Control.Concurrent.Async    (async, wait)
import           Control.Concurrent          (threadDelay)
import           Control.Concurrent.Chan     (newChan, readChan)
import           Control.Monad               (forM_, void)
import           Control.Monad.Exception     (MonadException)
import           Control.Monad.Fix           (MonadFix)
import           Control.Monad.Identity      (Identity (..))
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Control.Monad.Reader
import           Control.Monad.Ref           (MonadRef, Ref, readRef)
import           Data.Dependent.Sum          (DSum ((:=>)))
import           Data.Function               (fix)
import           Data.Word                   (Word32)
import           Reflex                      hiding (Additive)
import           Reflex.Host.Class
import           SDL                         hiding (Event)

import           Reflex.SDL2.Internal


------------------------------------------------------------------------------
-- | A collection of constraints that represent the default reflex-sdl2 network.
type ReflexSDL2 r t m =
  ( Reflex t
  , MonadHold t m
  , MonadSample t m
  , MonadAdjust t m
  , PostBuild t m
  , PerformEvent t m
  , MonadFix m
  , MonadIO m
  , MonadIO (Performable m)
  , MonadReader (SystemEvents r t) m
  , MonadReflexCreateTrigger t m
  , TriggerEvent t m
  )


------------------------------------------------------------------------------
-- | Provides a basic implementation of 'ReflexSDL2' constraints.
newtype ReflexSDL2T r t (m :: * -> *) a =
  ReflexSDL2T { runReflexSDL2T :: ReaderT (SystemEvents r t) m a }

deriving instance (ReflexHost t, Functor m)        => Functor (ReflexSDL2T r t m)
deriving instance (ReflexHost t, Applicative m)    => Applicative (ReflexSDL2T r t m)
deriving instance (ReflexHost t, Monad m)          => Monad (ReflexSDL2T r t m)
deriving instance (ReflexHost t, MonadFix m)       => MonadFix (ReflexSDL2T r t m)
deriving instance (ReflexHost t, Monad m)          => MonadReader (SystemEvents r t) (ReflexSDL2T r t m)
deriving instance (ReflexHost t, MonadIO m)        => MonadIO (ReflexSDL2T r t m)
deriving instance ReflexHost t => MonadTrans (ReflexSDL2T r t)
deriving instance (ReflexHost t, MonadException m) => MonadException (ReflexSDL2T r t m)


------------------------------------------------------------------------------
-- | 'ReflexSDL2T' is an instance of 'PostBuild'.
instance (Reflex t, ReflexHost t, Monad m) => PostBuild t (ReflexSDL2T r t m) where
  getPostBuild = asks sysPostBuildEvent


------------------------------------------------------------------------------
-- | 'ReflexSDL2T' is an instance of 'PerformEvent'.
instance (ReflexHost t, PerformEvent t m) => PerformEvent t (ReflexSDL2T r t m) where
  type Performable (ReflexSDL2T r t m) = ReflexSDL2T r t (Performable m)
  performEvent_ = ReflexSDL2T . performEvent_ . fmap runReflexSDL2T
  performEvent  = ReflexSDL2T . performEvent  . fmap runReflexSDL2T


------------------------------------------------------------------------------
instance ( ReflexHost t
         , MonadReflexCreateTrigger t m
         , Monad m
         , Applicative m
         ) => MonadReflexCreateTrigger t (ReflexSDL2T r t m) where
  newEventWithTrigger = ReflexSDL2T . newEventWithTrigger
  newFanEventWithTrigger f = ReflexSDL2T $ newFanEventWithTrigger f


instance ( ReflexHost t
         , TriggerEvent t m
         , MonadReflexCreateTrigger t m
         , Monad m
         , MonadRef m
         , Ref m ~ Ref IO
         ) => TriggerEvent t (ReflexSDL2T r t m) where
  newTriggerEvent = lift newTriggerEvent
  newTriggerEventWithOnComplete = lift newTriggerEventWithOnComplete
  newEventWithLazyTriggerWithOnComplete = lift . newEventWithLazyTriggerWithOnComplete

------------------------------------------------------------------------------
-- | 'ReflexSDL2T' is an instance of 'MonadAdjust'.
instance ( Reflex t
         , ReflexHost t
         , MonadAdjust t m
         , Monad m
         --, PrimMonad (HostFrame t)
         ) => MonadAdjust t (ReflexSDL2T r t m) where
  runWithReplace ma evmb =
    ReflexSDL2T $ runWithReplace (runReflexSDL2T ma) (runReflexSDL2T <$> evmb)
  traverseDMapWithKeyWithAdjust kvma dMapKV = ReflexSDL2T .
    traverseDMapWithKeyWithAdjust (\ka -> runReflexSDL2T . kvma ka) dMapKV
  traverseDMapWithKeyWithAdjustWithMove kvma dMapKV = ReflexSDL2T .
    traverseDMapWithKeyWithAdjustWithMove (\ka -> runReflexSDL2T . kvma ka) dMapKV


------------------------------------------------------------------------------
-- | 'ReflexSDL2T' is an instance of 'MonadHold'.
instance ( ReflexHost t
         , Applicative m
         , Monad m
         , MonadSample t m
         ) => MonadSample t (ReflexSDL2T r t m) where
  sample = lift . sample


------------------------------------------------------------------------------
-- | 'ReflexSDL2T' is an instance of 'MonadHold'.
instance (ReflexHost t, MonadHold t m) => MonadHold t (ReflexSDL2T r t m) where
  hold a = lift . hold a
  holdDyn a = lift . holdDyn a
  holdIncremental p = lift . holdIncremental p
  buildDynamic ma = lift . buildDynamic ma


--------------------------------------------------------------------------------
-- | Returns an event that fires each frame with the number of milliseconds
-- since the last frame.
-- Be aware that subscribing to this 'Event' (by using it in a monadic action)
-- will result in your app running sdl2's event loop every frame.
getDeltaTickEvent :: ReflexSDL2 r t m => m (Event t Word32)
getDeltaTickEvent = do
  let f (lastTick, _) thisTick = (thisTick, thisTick - lastTick)
  evTickAndDel <- accum f (0, 0) =<< asks sysTicksEvent
  return $ snd <$> evTickAndDel


--------------------------------------------------------------------------------
-- | Returns an 'Event' that fires every @n@ number of milliseconds. This is
-- useful for animation timers, etc.
getRecurringTimerEvent
  :: ReflexSDL2 r t m
  => Int
  -- ^ @n@ - the 'Event's recurring interval in milliseconds.
  -> m (Event t ())
getRecurringTimerEvent n = do
  evPB <- getPostBuild
  performEventAsync $ ffor evPB $ \() cb -> void $
    liftIO $ async $ fix $ \loop -> do
      threadDelay $ n * 1000
      cb ()
      loop


--------------------------------------------------------------------------------
-- | Runs an asynchronous 'IO' action and returns an 'Event' that fires with the
-- result.
getAsyncEvent :: ReflexSDL2 r t m => IO a -> m (Event t a)
getAsyncEvent action = do
  evPB <- getPostBuild
  performEventAsync $ ffor evPB $ \() cb -> void $ liftIO $ do
    aa <- async action
    a  <- wait aa
    cb a


getTicksEvent :: ReflexSDL2 r t m => m (Event t Word32)
getTicksEvent = asks sysTicksEvent

getAnySDLEvent :: ReflexSDL2 r t m => m (Event t EventPayload)
getAnySDLEvent = asks sysAnySDLEvent

getWindowShownEvent :: ReflexSDL2 r t m => m (Event t WindowShownEventData)
getWindowShownEvent = asks sysWindowShownEvent

getWindowHiddenEvent :: ReflexSDL2 r t m => m (Event t WindowHiddenEventData)
getWindowHiddenEvent = asks sysWindowHiddenEvent

getWindowExposedEvent :: ReflexSDL2 r t m => m (Event t WindowExposedEventData)
getWindowExposedEvent = asks sysWindowExposedEvent

getWindowMovedEvent :: ReflexSDL2 r t m => m (Event t WindowMovedEventData)
getWindowMovedEvent = asks sysWindowMovedEvent

getWindowResizedEvent :: ReflexSDL2 r t m => m (Event t WindowResizedEventData)
getWindowResizedEvent = asks sysWindowResizedEvent

getWindowSizeChangedEvent :: ReflexSDL2 r t m => m (Event t WindowSizeChangedEventData)
getWindowSizeChangedEvent = asks sysWindowSizeChangedEvent

getWindowMinimizedEvent :: ReflexSDL2 r t m => m (Event t WindowMinimizedEventData)
getWindowMinimizedEvent = asks sysWindowMinimizedEvent

getWindowMaximizedEvent :: ReflexSDL2 r t m => m (Event t WindowMaximizedEventData)
getWindowMaximizedEvent = asks sysWindowMaximizedEvent

getWindowRestoredEvent :: ReflexSDL2 r t m => m (Event t WindowRestoredEventData)
getWindowRestoredEvent = asks sysWindowRestoredEvent

getWindowGainedMouseFocusEvent :: ReflexSDL2 r t m => m (Event t WindowGainedMouseFocusEventData)
getWindowGainedMouseFocusEvent = asks sysWindowGainedMouseFocusEvent

getWindowLostMouseFocusEvent :: ReflexSDL2 r t m => m (Event t WindowLostMouseFocusEventData)
getWindowLostMouseFocusEvent = asks sysWindowLostMouseFocusEvent

getWindowGainedKeyboardFocusEvent :: ReflexSDL2 r t m => m (Event t WindowGainedKeyboardFocusEventData)
getWindowGainedKeyboardFocusEvent = asks sysWindowGainedKeyboardFocusEvent

getWindowLostKeyboardFocusEvent :: ReflexSDL2 r t m => m (Event t WindowLostKeyboardFocusEventData)
getWindowLostKeyboardFocusEvent = asks sysWindowLostKeyboardFocusEvent

getWindowClosedEvent :: ReflexSDL2 r t m => m (Event t WindowClosedEventData)
getWindowClosedEvent = asks sysWindowClosedEvent

getKeyboardEvent :: ReflexSDL2 r t m => m (Event t KeyboardEventData)
getKeyboardEvent = asks sysKeyboardEvent

getTextEditingEvent :: ReflexSDL2 r t m => m (Event t TextEditingEventData)
getTextEditingEvent = asks sysTextEditingEvent

getTextInputEvent :: ReflexSDL2 r t m => m (Event t TextInputEventData)
getTextInputEvent = asks sysTextInputEvent

getKeymapChangedEvent :: ReflexSDL2 r t m => m (Event t ())
getKeymapChangedEvent = asks sysKeymapChangedEvent

getMouseMotionEvent :: ReflexSDL2 r t m => m (Event t MouseMotionEventData)
getMouseMotionEvent = asks sysMouseMotionEvent

getMouseButtonEvent :: ReflexSDL2 r t m => m (Event t MouseButtonEventData)
getMouseButtonEvent = asks sysMouseButtonEvent

getMouseWheelEvent :: ReflexSDL2 r t m => m (Event t MouseWheelEventData)
getMouseWheelEvent = asks sysMouseWheelEvent

getJoyAxisEvent :: ReflexSDL2 r t m => m (Event t JoyAxisEventData)
getJoyAxisEvent = asks sysJoyAxisEvent

getJoyBallEvent :: ReflexSDL2 r t m => m (Event t JoyBallEventData)
getJoyBallEvent = asks sysJoyBallEvent

getJoyHatEvent :: ReflexSDL2 r t m => m (Event t JoyHatEventData)
getJoyHatEvent = asks sysJoyHatEvent

getJoyButtonEvent :: ReflexSDL2 r t m => m (Event t JoyButtonEventData)
getJoyButtonEvent = asks sysJoyButtonEvent

getJoyDeviceEvent :: ReflexSDL2 r t m => m (Event t JoyDeviceEventData)
getJoyDeviceEvent = asks sysJoyDeviceEvent

getControllerAxisEvent :: ReflexSDL2 r t m => m (Event t ControllerAxisEventData)
getControllerAxisEvent = asks sysControllerAxisEvent

getControllerButtonEvent :: ReflexSDL2 r t m => m (Event t ControllerButtonEventData)
getControllerButtonEvent = asks sysControllerButtonEvent

getControllerDeviceEvent :: ReflexSDL2 r t m => m (Event t ControllerDeviceEventData)
getControllerDeviceEvent = asks sysControllerDeviceEvent

getAudioDeviceEvent :: ReflexSDL2 r t m => m (Event t AudioDeviceEventData)
getAudioDeviceEvent = asks sysAudioDeviceEvent

getQuitEvent :: ReflexSDL2 r t m => m (Event t ())
getQuitEvent = asks sysQuitEvent

getUserEvent :: ReflexSDL2 r t m => m (Event t UserEventData)
getUserEvent = asks sysUserEvent

getSysWMEvent :: ReflexSDL2 r t m => m (Event t SysWMEventData)
getSysWMEvent = asks sysSysWMEvent

getTouchFingerEvent :: ReflexSDL2 r t m => m (Event t TouchFingerEventData)
getTouchFingerEvent = asks sysTouchFingerEvent

getMultiGestureEvent :: ReflexSDL2 r t m => m (Event t MultiGestureEventData)
getMultiGestureEvent = asks sysMultiGestureEvent

getDollarGestureEvent :: ReflexSDL2 r t m => m (Event t DollarGestureEventData)
getDollarGestureEvent = asks sysDollarGestureEvent

getDropEvent :: ReflexSDL2 r t m => m (Event t DropEventData)
getDropEvent = asks sysDropEvent

getClipboardUpdateEvent :: ReflexSDL2 r t m => m (Event t ())
getClipboardUpdateEvent = asks sysClipboardUpdateEvent

getUnknownEvent :: ReflexSDL2 r t m => m (Event t UnknownEventData)
getUnknownEvent = asks sysUnknownEvent

getUserData :: ReflexSDL2 r t m => m r
getUserData = asks sysUserData


--------------------------------------------------------------------------------
-- | The concrete/specialized type used to run reflex-sdl2 apps.
type ConcreteReflexSDL2 r =
  ReflexSDL2T r Spider (TriggerEventT Spider (PerformEventT Spider (SpiderHost Global)))


------------------------------------------------------------------------------
-- | Host a reflex-sdl2 app.
host
  :: r
  -- ^ A user data value of type 'r'.
  -- Use @asks 'sysUserData'@ to access this value within your app network.
  -> ConcreteReflexSDL2 r a
  -- ^ A concrete reflex-sdl2 network to run.
  -> IO ()
host sysUserData app = runSpiderHost $ do
  -- Get events and trigger refs for all things that can happen.
  (sysPostBuildEvent,                                 trPostBuildRef) <- newEventWithTriggerRef
  (sysAnySDLEvent,                                       trAnySDLRef) <- newEventWithTriggerRef
  (sysTicksEvent,                                         trTicksRef) <- newEventWithTriggerRef
  (sysWindowShownEvent,                             trWindowShownRef) <- newEventWithTriggerRef
  (sysWindowHiddenEvent,                           trWindowHiddenRef) <- newEventWithTriggerRef
  (sysWindowExposedEvent,                         trWindowExposedRef) <- newEventWithTriggerRef
  (sysWindowMovedEvent,                             trWindowMovedRef) <- newEventWithTriggerRef
  (sysWindowResizedEvent,                         trWindowResizedRef) <- newEventWithTriggerRef
  (sysWindowSizeChangedEvent,                 trWindowSizeChangedRef) <- newEventWithTriggerRef
  (sysWindowMinimizedEvent,                     trWindowMinimizedRef) <- newEventWithTriggerRef
  (sysWindowMaximizedEvent,                     trWindowMaximizedRef) <- newEventWithTriggerRef
  (sysWindowRestoredEvent,                       trWindowRestoredRef) <- newEventWithTriggerRef
  (sysWindowGainedMouseFocusEvent,       trWindowGainedMouseFocusRef) <- newEventWithTriggerRef
  (sysWindowLostMouseFocusEvent,           trWindowLostMouseFocusRef) <- newEventWithTriggerRef
  (sysWindowGainedKeyboardFocusEvent, trWindowGainedKeyboardFocusRef) <- newEventWithTriggerRef
  (sysWindowLostKeyboardFocusEvent,     trWindowLostKeyboardFocusRef) <- newEventWithTriggerRef
  (sysWindowClosedEvent,                           trWindowClosedRef) <- newEventWithTriggerRef
  (sysKeyboardEvent,                                   trKeyboardRef) <- newEventWithTriggerRef
  (sysTextEditingEvent,                             trTextEditingRef) <- newEventWithTriggerRef
  (sysTextInputEvent,                                 trTextInputRef) <- newEventWithTriggerRef
  (sysKeymapChangedEvent,                         trKeymapChangedRef) <- newEventWithTriggerRef
  (sysMouseMotionEvent,                             trMouseMotionRef) <- newEventWithTriggerRef
  (sysMouseButtonEvent,                             trMouseButtonRef) <- newEventWithTriggerRef
  (sysMouseWheelEvent,                               trMouseWheelRef) <- newEventWithTriggerRef
  (sysJoyAxisEvent,                                     trJoyAxisRef) <- newEventWithTriggerRef
  (sysJoyBallEvent,                                     trJoyBallRef) <- newEventWithTriggerRef
  (sysJoyHatEvent,                                       trJoyHatRef) <- newEventWithTriggerRef
  (sysJoyButtonEvent,                                 trJoyButtonRef) <- newEventWithTriggerRef
  (sysJoyDeviceEvent,                                 trJoyDeviceRef) <- newEventWithTriggerRef
  (sysControllerAxisEvent,                       trControllerAxisRef) <- newEventWithTriggerRef
  (sysControllerButtonEvent,                   trControllerButtonRef) <- newEventWithTriggerRef
  (sysControllerDeviceEvent,                   trControllerDeviceRef) <- newEventWithTriggerRef
  (sysAudioDeviceEvent,                             trAudioDeviceRef) <- newEventWithTriggerRef
  (sysQuitEvent,                                           trQuitRef) <- newEventWithTriggerRef
  (sysUserEvent,                                           trUserRef) <- newEventWithTriggerRef
  (sysSysWMEvent,                                         trSysWMRef) <- newEventWithTriggerRef
  (sysTouchFingerEvent,                             trTouchFingerRef) <- newEventWithTriggerRef
  (sysMultiGestureEvent,                           trMultiGestureRef) <- newEventWithTriggerRef
  (sysDollarGestureEvent,                         trDollarGestureRef) <- newEventWithTriggerRef
  (sysDropEvent,                                           trDropRef) <- newEventWithTriggerRef
  (sysClipboardUpdateEvent,                     trClipboardUpdateRef) <- newEventWithTriggerRef
  (sysUnknownEvent,                                     trUnknownRef) <- newEventWithTriggerRef

  chan <- liftIO newChan
  -- Build the network and get our firing command to trigger the post build event.
  (_, FireCommand fire) <-
    hostPerformEventT $ runTriggerEventT (runReaderT (runReflexSDL2T app) SystemEvents{..}) chan

  -- Trigger the post build event.
  (readRef trPostBuildRef >>=) . mapM_ $ \tr ->
    fire [tr :=> Identity ()] $ return ()

  void $ liftIO $ async $ runSpiderHost $ fix $ \loop -> do
    -- Fire any events waiting in our chan that may have been
    -- created by the network itself.
    triggerInvocations <- liftIO $ readChan chan
    forM_ triggerInvocations $
      \(EventTriggerRef etr :=> TriggerInvocation a _) ->
        (readRef etr >>=) . mapM_ $ \tr ->
          fire [tr :=> Identity a] $ return ()
    -- Run any callbacks that async events in the chan are
    -- waiting for.
    forM_ triggerInvocations $
      \(_ :=> TriggerInvocation _ cb) -> liftIO cb
    loop


  ---- Loop forever getting sdl2 events and triggering them.
  fix $ \loop -> do
    -- Fire any tick events, if anyone is listening.
    -- If someone _is_ listening, we need to fire an
    -- event every frame - otherwise we can wait around
    -- for an sdl event to update the network.
    shouldWait <- readRef trTicksRef >>= \case
      Nothing -> return True
      Just tr -> do
        t <- ticks
        void $ fire [tr :=> Identity t] $ return ()
        return False


    payloads <- if shouldWait
                then (:) <$> (    eventPayload <$> waitEvent)
                         <*> (map eventPayload <$> pollEvents)
                else map eventPayload <$> pollEvents

    forM_ payloads $ \case
      WindowShownEvent dat -> (readRef trWindowShownRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowHiddenEvent dat -> (readRef trWindowHiddenRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowExposedEvent dat -> (readRef trWindowExposedRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowMovedEvent dat -> (readRef trWindowMovedRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowResizedEvent dat -> (readRef trWindowResizedRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowSizeChangedEvent dat -> (readRef trWindowSizeChangedRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowMinimizedEvent dat -> (readRef trWindowMinimizedRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowMaximizedEvent dat -> (readRef trWindowMaximizedRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowRestoredEvent dat -> (readRef trWindowRestoredRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowGainedMouseFocusEvent dat -> (readRef trWindowGainedMouseFocusRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowLostMouseFocusEvent dat -> (readRef trWindowLostMouseFocusRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowGainedKeyboardFocusEvent dat -> (readRef trWindowGainedKeyboardFocusRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowLostKeyboardFocusEvent dat -> (readRef trWindowLostKeyboardFocusRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      WindowClosedEvent dat -> (readRef trWindowClosedRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      KeyboardEvent dat -> (readRef trKeyboardRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      TextEditingEvent dat -> (readRef trTextEditingRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      TextInputEvent dat -> (readRef trTextInputRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      KeymapChangedEvent -> (readRef trKeymapChangedRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity ()] $ return ()
      MouseMotionEvent dat -> (readRef trMouseMotionRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      MouseButtonEvent dat -> (readRef trMouseButtonRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      MouseWheelEvent dat -> (readRef trMouseWheelRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      JoyAxisEvent dat -> (readRef trJoyAxisRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      JoyBallEvent dat -> (readRef trJoyBallRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      JoyHatEvent dat -> (readRef trJoyHatRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      JoyButtonEvent dat -> (readRef trJoyButtonRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      JoyDeviceEvent dat -> (readRef trJoyDeviceRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      ControllerAxisEvent dat -> (readRef trControllerAxisRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      ControllerButtonEvent dat -> (readRef trControllerButtonRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      ControllerDeviceEvent dat -> (readRef trControllerDeviceRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      AudioDeviceEvent dat -> (readRef trAudioDeviceRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      QuitEvent -> (readRef trQuitRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity ()] $ return ()
      UserEvent dat -> (readRef trUserRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      SysWMEvent dat -> (readRef trSysWMRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      TouchFingerEvent dat -> (readRef trTouchFingerRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      MultiGestureEvent dat -> (readRef trMultiGestureRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      DollarGestureEvent dat -> (readRef trDollarGestureRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      DropEvent dat -> (readRef trDropRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()
      ClipboardUpdateEvent -> (readRef trClipboardUpdateRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity ()] $ return ()
      UnknownEvent dat -> (readRef trUnknownRef >>=) . mapM_ $ \tr ->
        fire [tr :=> Identity dat] $ return ()

    -- Fire an event for the wrapped payload as well.
    (readRef trAnySDLRef >>=) . mapM_ $ \tr ->
      forM_ payloads $ \payload ->
        fire [tr :=> Identity payload] $ return ()

    loop


------------------------------------------------------------------------------
-- | Like 'putStrLn', but for 'Event's.
putDebugLnE
  :: (PerformEvent t m, Reflex t, MonadIO (Performable m))
  => Event t a
  -- ^ The 'Event' to trigger the print.
  -> (a -> String)
  -- ^ A function to show the 'Event's value.
  -> m ()
putDebugLnE ev showf = performEvent_ $ liftIO . putStrLn . showf <$> ev


------------------------------------------------------------------------------
-- | Run a placeholder network until the given 'Event' fires, then replace it
-- with the network of the 'Event's value. This process is repeated each time
-- the 'Event' fires a new network. Returns a 'Dynamic' of the inner network
-- that updates any time the 'Event' fires.
holdView :: ReflexSDL2 r t m => m a -> Event t (m a) -> m (Dynamic t a)
holdView child0 newChild = do
  (result0, newResult) <- runWithReplace child0 newChild
  holdDyn result0 newResult


------------------------------------------------------------------------------
-- | Run a 'Dynamic'ally changing network, replacing the current one with the
-- new one every time the 'Dynamic' updates. Returns an 'Event' of the inner
-- network's result value that fires every time the 'Dynamic' changes.
dynView :: ReflexSDL2 r t m => Dynamic t (m a) -> m (Event t a)
dynView child = do
  evPB <- getPostBuild
  let newChild = leftmost [updated child, tagCheap (current child) evPB]
  snd <$> runWithReplace (return ()) newChild
