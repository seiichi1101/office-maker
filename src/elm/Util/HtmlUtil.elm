module Util.HtmlUtil exposing (..)

import Native.HtmlUtil
import Html exposing (Html, Attribute, text)
import Html.App
import Html.Attributes
import Html.Events exposing (on, onWithOptions)
import Json.Decode as Decode exposing (..)
import Util.File exposing (..)
import Task exposing (Task)
import Process

type Error =
  IdNotFound String | Unexpected String

-- optional : (a -> Html msg) -> Maybe a -> Html msg
-- optional f maybe =
--   case maybe of
--     Just a -> f a
--     Nothing -> text ""

decodeClientXY : Decoder (Int, Int)
decodeClientXY =
  object2 (,)
    ("clientX" := int)
    ("clientY" := int)

decodeKeyCode : Decoder Int
decodeKeyCode =
  at [ "keyCode" ] int


targetSelectionStart : Decoder Int
targetSelectionStart =
  Decode.at ["target", "selectionStart"] Decode.int


decodeKeyCodeAndSelectionStart : Decoder (Int, Int)
decodeKeyCodeAndSelectionStart =
  Decode.object2 (,)
    ("keyCode" := int)
    ("target" := Decode.object1 identity ("selectionStart" := int))


focus : String -> Task Error ()
focus id =
  Process.sleep 100 `Task.andThen` \_ ->
  Task.mapError
    (always (IdNotFound id))
    (Native.HtmlUtil.focus id)

blur : String -> Task Error ()
blur id =
  Process.sleep 100 `Task.andThen` \_ ->
  Task.mapError
    (always (IdNotFound id))
    (Native.HtmlUtil.blur id)

onSubmit' : a -> Attribute a
onSubmit' e =
  onWithOptions
    "onsubmit" { stopPropagation = True, preventDefault = False } (Decode.succeed e)

onMouseMove' : ((Int, Int) -> a) -> Attribute a
onMouseMove' f =
  onWithOptions
    "mousemove" { stopPropagation = True, preventDefault = True } (Decode.map f decodeClientXY)

onMouseEnter' : a -> Attribute a
onMouseEnter' e =
  onWithOptions
    "mouseenter" { stopPropagation = True, preventDefault = True } (Decode.succeed e)

onMouseLeave' : a -> Attribute a
onMouseLeave' e =
  onWithOptions
    "mouseleave" { stopPropagation = True, preventDefault = True } (Decode.succeed e)

onMouseUp' : a -> Attribute a
onMouseUp' e =
  on "mouseup" (Decode.succeed e)

onMouseDown' : a -> Attribute a
onMouseDown' e =
  onWithOptions "mousedown" { stopPropagation = True, preventDefault = True } (Decode.succeed e)

onDblClick' : a -> Attribute a
onDblClick' e =
  onWithOptions "dblclick" { stopPropagation = True, preventDefault = True } (Decode.succeed e)

onClick' : a -> Attribute a
onClick' e =
  onWithOptions "click" { stopPropagation = True, preventDefault = True } (Decode.succeed e)

onInput : (String -> a) -> Attribute a
onInput f =
  on "input" (Decode.map f Html.Events.targetValue)

onInput' : (String -> a) -> Attribute a
onInput' f =
  onWithOptions "input" { stopPropagation = True, preventDefault = True } (Decode.map f Html.Events.targetValue)

onChange' : (String -> a) -> Attribute a
onChange' f =
  onWithOptions "change" { stopPropagation = True, preventDefault = True } (Decode.map f Html.Events.targetValue)

-- onKeyUp' : Address KeyboardEvent -> Attribute
-- onKeyUp' address =
--   on "keyup" decodeKeyboardEvent (Signal.message address)

onKeyDown' : (Int -> a) -> Attribute a
onKeyDown' f =
  onWithOptions "keydown" { stopPropagation = True, preventDefault = True } (Decode.map f decodeKeyCode)

onKeyDown'' : (Int -> a) -> Attribute a
onKeyDown'' f =
  on "keydown" (Decode.map f decodeKeyCode)

onContextMenu' : a -> Attribute a
onContextMenu' e =
  onWithOptions "contextmenu" { stopPropagation = True, preventDefault = True } (Decode.succeed e)

onMouseWheel : (Float -> a) -> Attribute a
onMouseWheel toAction =
  onWithOptions "wheel" { stopPropagation = True, preventDefault = True } (Decode.map toAction decodeWheelEvent)

mouseDownDefence : a -> Attribute a
mouseDownDefence e =
  onMouseDown' e


decodeWheelEvent : Decoder Float
decodeWheelEvent =
    (oneOf
      [ at [ "deltaY" ] float
      , at [ "wheelDelta" ] float |> map (\v -> -v)
      ])
    `andThen` (\value -> if value /= 0 then succeed value else fail "Wheel of 0")


form' : a -> List (Attribute a) -> List (Html a) -> Html a
form' action attribtes children =
  Html.form
    ([ Html.Attributes.action "javascript:void(0);"
    , Html.Attributes.method "POST"
    , Html.Events.onSubmit action
    ] ++ attribtes)
    children

fileLoadButton : (FileList -> msg) -> List (String, String) -> String -> Html msg
fileLoadButton tagger styles text =
  Html.label
    [ Html.Attributes.style styles ]
    [ Html.text text
    , Html.input
        [ Html.Attributes.type' "file"
        , Html.Attributes.style [("display", "none")]
        , on "change" decodeFile
        ]
        [] |> Html.App.map tagger
    ]
