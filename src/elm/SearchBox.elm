module SearchBox exposing (..) -- where

import Task
import Html exposing (..)
import Html.App as App
import Html.Attributes exposing (..)
import Html.Events
import Model.Equipments as Equipments exposing (..)
import Model.API as API

import Util.HtmlUtil exposing (..)

import View.Styles as Styles

type Msg =
    Input String
  | Results (List (Equipment, String))
  | Submit Bool
  | SelectResult String
  | Error API.Error

type Event =
    OnError API.Error
  | OnResults
  | OnSelectResult String
  | OnSubmit
  | None

type alias Model =
  { query : String
  , results : Maybe (List (Equipment, String))
  }

init : Maybe String -> Model
init query =
  { query = Maybe.withDefault "" query
  , results = Nothing
  }

doSearch : (Msg -> a) -> Bool -> String -> Model -> (Model, Cmd a)
doSearch transformMsg withPrivate query model =
  ({ model | query = query }
  , if query /= "" then
      Cmd.map transformMsg (searchCmd withPrivate query)
    else
      Cmd.none
  )

update : Msg -> Model -> (Model, Cmd Msg, Event)
update msg model =
  case {-Debug.log "searchbox"-} msg of
    Input query ->
        ({ model | query = query }, Cmd.none, None)
    Submit withPrivate ->
        (model, Cmd.none, OnSubmit)
    Results results ->
        ({ model | results = Just results }, Cmd.none, OnResults)
    SelectResult id ->
        (model, Cmd.none, (OnSelectResult id))
    Error apiError ->
        (model, Cmd.none, (OnError apiError))

searchCmd : Bool -> String -> Cmd Msg
searchCmd withPrivate query =
  Task.perform Error Results (API.search withPrivate query)


equipmentsInFloor : String -> Model -> List Equipment
equipmentsInFloor floorId model =
  case model.results of
    Nothing ->
      []
    Just results ->
      List.filterMap (\(e, id) -> if id == floorId then Just e else Nothing) results

view : (Msg -> msg) -> Bool -> Model -> Html msg
view translateMsg searchWithPrivate model =
  App.map translateMsg <|
    form' (Submit searchWithPrivate)
      [ ]
      [ input
        [ type' "input"
        , placeholder "Search"
        , style Styles.searchBox
        , value model.query
        , onInput Input
        ]
        []
      ]

resultView : (Msg -> msg) -> (Equipment -> String -> Html msg) -> (Equipment, String) -> Html msg
resultView translateMsg format (e, floorId) =
    li
      [ Html.Events.onClick (translateMsg <| SelectResult (idOf e))
      , style Styles.searchResultItem
      ]
      [ format e floorId ]

resultsView : (Msg -> msg) -> (Equipment -> String -> Html msg) -> Model -> Html msg
resultsView translateMsg format model =
    case model.results of
      Nothing ->
        text ""
      Just [] ->
        div [] [ text "Nothing found." ]
      Just results ->
        ul
          [ style Styles.ul ]
          (List.map (resultView translateMsg format) results)
