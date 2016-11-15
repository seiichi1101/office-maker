module Model.Object exposing (..)

import Time exposing (Time)

type alias Id = String
type alias FloorId = String
type alias PersonId = String
type alias FloorVersion = Int


type Shape
  = Rectangle
  | Ellipse


type Object =
  Object
    { id : Id
    , floorId : FloorId
    , floorVersion : Maybe FloorVersion
    , rect : (Int, Int, Int, Int) -- (x, y, width, height)
    , backgroundColor : String
    , name : String
    , fontSize : Float
    , updateAt : Maybe Time
    , extension : ObjectExtension
    }


type ObjectExtension
  = Desk (Maybe PersonId)
  | Label String Shape


type ObjectPropertyChange
  = Name String String
  | Size (Int, Int) (Int, Int)
  | Position (Int, Int) (Int, Int)
  | BackgroundColor String String
  | Color String String
  | FontSize Float Float
  | Shape Shape Shape
  | Person (Maybe PersonId) (Maybe PersonId)


modifyAll : List ObjectPropertyChange -> Object -> Object
modifyAll changes object =
  changes
    |> List.foldl modify object


modify : ObjectPropertyChange -> Object -> Object
modify change object =
  case change of
    Name new old ->
      changeName new object

    Size new old ->
      changeSize new object

    Position new old ->
      move new object

    BackgroundColor new old ->
      changeBackgroundColor new object

    Color new old ->
      changeColor new object

    FontSize new old ->
      changeFontSize new object

    Shape new old ->
      changeShape new object

    Person new old ->
      setPerson new object


copyUpdateAt : Object -> Object -> Object
copyUpdateAt (Object old) (Object new) =
  Object { new | updateAt = old.updateAt }


isDesk : Object -> Bool
isDesk (Object object) =
  case object.extension of
    Desk _ ->
      True

    _ ->
      False


isLabel : Object -> Bool
isLabel (Object object) =
  case object.extension of
    Label _ _ ->
      True

    _ ->
      False


initDesk : Id -> FloorId -> Maybe FloorVersion -> (Int, Int, Int, Int) -> String -> String -> Float -> Maybe Time -> Maybe PersonId -> Object
initDesk id floorId floorVersion rect backgroundColor name fontSize updateAt personId =
  Object
    { id = id
    , floorId = floorId
    , floorVersion = floorVersion
    , rect = rect
    , backgroundColor = backgroundColor
    , name = name
    , fontSize = fontSize
    , updateAt = updateAt
    , extension = Desk personId
    }


initLabel : Id -> FloorId -> Maybe FloorVersion -> (Int, Int, Int, Int) -> String -> String -> Float -> Maybe Time -> String -> Shape -> Object
initLabel id floorId floorVersion rect backgroundColor name fontSize updateAt color shape =
  Object
    { id = id
    , floorId = floorId
    , floorVersion = floorVersion
    , rect = rect
    , backgroundColor = backgroundColor
    , name = name
    , fontSize = fontSize
    , updateAt = updateAt
    , extension = Label color shape
    }


position : Object -> (Int, Int)
position (Object object) =
  case object.rect of
    (x, y, _, _) ->
      (x, y)


changeId : Id -> Object -> Object
changeId id (Object object) =
  Object { object | id = id }


changeFloorId : FloorId -> Object -> Object
changeFloorId floorId (Object object) =
  Object { object | floorId = floorId }


changeBackgroundColor : String -> Object -> Object
changeBackgroundColor backgroundColor (Object object) =
  Object { object | backgroundColor = backgroundColor }


changeColor : String -> Object -> Object
changeColor color (Object object) =
  case object.extension of
    Desk _ ->
      Object object

    Label _ shape ->
      Object { object | extension = Label color shape }


changeShape : Shape -> Object -> Object
changeShape shape (Object object) =
  case object.extension of
    Desk _ ->
      Object object

    Label color _ ->
      Object { object | extension = Label color shape }


changeName : String -> Object -> Object
changeName name (Object object) =
  Object { object | name = name }


changeSize : (Int, Int) -> Object -> Object
changeSize (w, h) (Object object) =
  case object.rect of
    (x, y, _, _) ->
      Object { object | rect = (x, y, w, h) }


move : (Int, Int) -> Object -> Object
move (x, y) (Object object) =
  case object.rect of
    (_, _, w, h) ->
      Object { object | rect = (x, y, w, h) }


rotate : Object -> Object
rotate (Object object) =
  case object.rect of
    (x, y, w, h) ->
      Object { object | rect = (x, y, h, w) }


setPerson : Maybe PersonId -> Object -> Object
setPerson personId (Object object) =
  case object.extension of
    Desk _ ->
      Object { object | extension = Desk personId }

    _ ->
      Object object


changeFontSize : Float -> Object -> Object
changeFontSize fontSize (Object object) =
  Object { object | fontSize = fontSize }


idOf : Object -> Id
idOf (Object object) =
  object.id


floorIdOf : Object -> FloorId
floorIdOf (Object object) =
  object.floorId


floorVersionOf : Object -> Maybe FloorVersion
floorVersionOf (Object object) =
  object.floorVersion


updateAtOf : Object -> Maybe Time
updateAtOf (Object object) =
  object.updateAt


nameOf : Object -> String
nameOf (Object object) =
  object.name


backgroundColorOf : Object -> String
backgroundColorOf (Object object) =
  object.backgroundColor


colorOf : Object -> String
colorOf (Object object) =
  case object.extension of
    Desk _ ->
      "#000"

    Label color _ ->
      color


defaultFontSize : Float
defaultFontSize = 20


fontSizeOf : Object -> Float
fontSizeOf (Object object) =
  object.fontSize


shapeOf : Object -> Shape
shapeOf (Object object) =
  case object.extension of
    Desk _ ->
      Rectangle

    Label _ shape ->
      shape


rect : Object -> (Int, Int, Int, Int)
rect (Object object) =
  object.rect


sizeOf : Object -> (Int, Int)
sizeOf object =
  let
    (x, y, w, h) =
      rect object
  in
    (w, h)


positionOf : Object -> (Int, Int)
positionOf object =
  let
    (x, y, w, h) =
      rect object
  in
    (x, y)


relatedPerson : Object -> Maybe PersonId
relatedPerson (Object object) =
  case object.extension of
    Desk personId ->
      personId

    _ ->
      Nothing


backgroundColorEditable : Object -> Bool
backgroundColorEditable _ = True


colorEditable : Object -> Bool
colorEditable = isLabel


shapeEditable : Object -> Bool
shapeEditable = isLabel


fontSizeEditable : Object -> Bool
fontSizeEditable _ = True


--
