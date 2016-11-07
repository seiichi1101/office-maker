module Page.Master.Update exposing (..)

import Time exposing (second)
import Task

import Debounce exposing (Debounce)

import API.API as API
import API.Cache as Cache exposing (Cache, UserState)
import Component.Header as Header

import Model.I18n as I18n exposing (Language(..))
import Model.User as User exposing (User)
import Model.Prototype exposing (Prototype)
import Model.ColorPalette as ColorPalette exposing (ColorPalette)

import Util.ListUtil as ListUtil

import Page.Master.Model exposing (Model)
import Page.Master.Msg exposing (Msg(..))
import Page.Master.PrototypeForm as PrototypeForm


type alias Flags =
  { apiRoot : String
  , accountServiceRoot : String
  , authToken : String
  , title : String
  , lang : String
  }


init : Flags -> (Model, Cmd Msg)
init flags =
  let
    apiConfig =
      { apiRoot = flags.apiRoot
      , accountServiceRoot = flags.accountServiceRoot
      , token = flags.authToken
      }

    defaultUserState =
      Cache.defaultUserState (if flags.lang == "ja" then JA else EN)
  in
    { apiConfig = apiConfig
    , title = flags.title
    , colorPalette = ColorPalette.empty
    , prototypes = []
    , headerState = Header.init
    , lang = defaultUserState.lang
    , saveColorDebounce = Debounce.init
    , savePrototypeDebounce = Debounce.init
    , error = Nothing
    } ! [ initCmd apiConfig defaultUserState ]


initCmd : API.Config -> UserState -> Cmd Msg
initCmd apiConfig defaultUserState =
  performAPI
    identity
    ( Cache.getWithDefault Cache.cache defaultUserState `Task.andThen` \userState ->
      API.getAuth apiConfig `Task.andThen` \user ->
        if not (User.isAdmin user) then
          Task.succeed NotAuthorized
        else
          API.getColors apiConfig `Task.andThen` \colorPalette ->
          API.getPrototypes apiConfig `Task.andThen` \prototypes ->
          Task.succeed (Loaded userState user colorPalette prototypes)
    )


performAPI : (a -> Msg) -> Task.Task API.Error a -> Cmd Msg
performAPI tagger task =
  Task.perform APIError tagger task


saveColorDebounceConfig : Debounce.Config Msg
saveColorDebounceConfig =
  { strategy = Debounce.later (0.6 * second)
  , transform = SaveColorDebounceMsg
  }


savePrototypeDebounceConfig : Debounce.Config Msg
savePrototypeDebounceConfig =
  { strategy = Debounce.later (0.6 * second)
  , transform = SavePrototypeDebounceMsg
  }


update : ({} -> Cmd Msg) -> Msg -> Model -> (Model, Cmd Msg)
update removeToken message model =
  case message of
    NoOp ->
      model ! []

    Loaded userState user colorPalette prototypes ->
      { model
      | colorPalette = colorPalette
      , prototypes = List.map PrototypeForm.fromPrototype prototypes
      } ! []

    UpdateHeaderState msg ->
      { model | headerState = Header.update msg model.headerState } ! []

    InputColor isBackground index color ->
      let
        colorPalette =
          (if isBackground then ColorPalette.setBackgroundColorAt else ColorPalette.setColorAt)
            index
            color
            model.colorPalette

        (saveColorDebounce, cmd) =
          Debounce.push
            saveColorDebounceConfig
            colorPalette
            model.saveColorDebounce
      in
        { model
        | colorPalette = colorPalette
        , saveColorDebounce = saveColorDebounce
        } ! [ cmd ]

    UpdatePrototype index prototype ->
      let
        prototypes =
          ListUtil.setAt index prototype model.prototypes

        (savePrototypeDebounce, cmd) =
          case PrototypeForm.toPrototype prototype of
            Ok prototype ->
              Debounce.push
                savePrototypeDebounceConfig
                prototype
                model.savePrototypeDebounce

            Err _ ->
              model.savePrototypeDebounce ! []
      in
        { model
        | prototypes = prototypes
        , savePrototypeDebounce = savePrototypeDebounce
        } ! [ cmd ]


    SaveColorDebounceMsg msg ->
      let
        (saveColorDebounce, cmd) =
          Debounce.update
            saveColorDebounceConfig
            (Debounce.takeLast (saveColorPalette model.apiConfig))
            msg
            model.saveColorDebounce
      in
        { model | saveColorDebounce = saveColorDebounce } ! [ cmd ]

    SavePrototypeDebounceMsg msg ->
      let
        (savePrototypeDebounce, cmd) =
          Debounce.update
            savePrototypeDebounceConfig
            (Debounce.takeLast (savePrototype model.apiConfig))
            msg
            model.savePrototypeDebounce
      in
        { model | savePrototypeDebounce = savePrototypeDebounce } ! [ cmd ]

    NotAuthorized ->
      model ! [ Task.perform (always NoOp) (always NoOp) API.goToLogin ]

    APIError e ->
      { model | error = Just (toString e) } ! []


saveColorPalette : API.Config -> ColorPalette -> Cmd Msg
saveColorPalette apiConfig colorPalette =
  performAPI (\_ -> NoOp) (API.saveColors apiConfig colorPalette)


savePrototype : API.Config -> Prototype -> Cmd Msg
savePrototype apiConfig prototype =
  performAPI (\_ -> NoOp) (API.savePrototype apiConfig prototype)
