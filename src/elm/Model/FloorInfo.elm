module Model.FloorInfo exposing (..)

import Dict exposing (Dict)
import Model.Floor exposing (FloorBase)


type alias FloorId = String


type FloorInfo
  = FloorInfo (Maybe FloorBase) FloorBase


init : Maybe FloorBase -> FloorBase -> FloorInfo
init publicFloor editingFloor =
  -- if publicFloor.id /= editingFloor.id then
  --   Debug.crash "IDs are not same: "
  -- else
    FloorInfo publicFloor editingFloor


idOf : FloorInfo -> FloorId
idOf (FloorInfo publicFloor editingFloor) =
  editingFloor.id


publicFloor : FloorInfo -> Maybe FloorBase
publicFloor (FloorInfo publicFloor editingFloor) =
  publicFloor


editingFloor : FloorInfo -> FloorBase
editingFloor (FloorInfo publicFloor editingFloor) =
  editingFloor


findPublicFloor : FloorId -> Dict FloorId FloorInfo -> Maybe FloorBase
findPublicFloor floorId floorsInfo =
  floorsInfo
    |> findFloor floorId
    |> Maybe.andThen publicFloor


findFloor : FloorId -> Dict FloorId FloorInfo -> Maybe FloorInfo
findFloor floorId floorsInfo =
  floorsInfo
    |> Dict.get floorId


mergeFloor : FloorBase -> Dict FloorId FloorInfo -> Dict FloorId FloorInfo
mergeFloor editingFloor floorsInfo =
  floorsInfo
    |> Dict.update editingFloor.id (Maybe.map (mergeFloorHelp editingFloor))


mergeFloorHelp : FloorBase -> FloorInfo -> FloorInfo
mergeFloorHelp floor (FloorInfo publicFloor editingFloor) =
  if floor.version < 0 then
    FloorInfo publicFloor floor
  else
    FloorInfo (Just floor) editingFloor


toPublicList : Dict FloorId FloorInfo -> List FloorBase
toPublicList floorsInfo =
  floorsInfo
    |> Dict.toList
    |> List.filterMap (Tuple.second >> publicFloor)
    |> List.sortBy .ord


toEditingList : Dict FloorId FloorInfo -> List FloorBase
toEditingList floorsInfo =
  floorsInfo
    |> Dict.toList
    |> List.map (Tuple.second >> editingFloor)
    |> List.sortBy .ord
