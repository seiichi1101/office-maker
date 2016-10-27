module Page.Map.Update exposing (..)

import Maybe
import Task exposing (Task, andThen, onError)
import Window
import String
import Process
import Keyboard
import Dict exposing (Dict)
import Navigation
import Time exposing (Time, second)
import Http
import Dom
import Basics.Extra exposing (never)
import Debounce exposing (Debounce)

import Util.ShortCut as ShortCut
import Util.IdGenerator as IdGenerator exposing (Seed)
import Util.DictUtil as DictUtil
import Util.File exposing (..)

import Model.Direction as Direction exposing (..)
import Model.EditMode as EditMode exposing (EditMode(..))
import Model.User as User exposing (User)
import Model.Person as Person exposing (Person)
import Model.Object as Object exposing (..)
import Model.ObjectsOperation as ObjectsOperation exposing (..)
import Model.Scale as Scale
import Model.Prototype exposing (Prototype)
import Model.Prototypes as Prototypes exposing (Prototypes, StampCandidate)
import Model.Floor as Floor exposing (Floor)
import Model.FloorDiff as FloorDiff
import Model.FloorInfo as FloorInfo exposing (FloorInfo)
import Model.Errors as Errors exposing (GlobalError(..))
import Model.I18n as I18n exposing (Language(..))
import Model.SearchResult as SearchResult exposing (SearchResult)
import Model.SaveRequest as SaveRequest exposing (SaveRequest(..), SaveRequestOpt(..))
import Model.EditingFloor as EditingFloor exposing (EditingFloor)
import Model.ClickboardData as ClickboardData

import API.API as API
import API.Cache as Cache exposing (Cache, UserState)

import Component.FloorProperty as FloorProperty
import Component.Header as Header
import Component.ObjectNameInput as ObjectNameInput

import Page.Map.Model as Model exposing (Model, ContextMenu(..), DraggingContext(..), Tab(..))
import Page.Map.Msg exposing (Msg(..))
import Page.Map.URL as URL exposing (URL)

type alias Flags =
  { apiRoot : String
  , accountServiceRoot : String
  , authToken : String
  , title : String
  , initialSize : (Int, Int)
  , randomSeed : (Int, Int)
  , visitDate : Float
  , lang : String
  }


subscriptions
  :  (({} -> Msg) -> Sub Msg)
  -> (({} -> Msg) -> Sub Msg)
  -> (({} -> Msg) -> Sub Msg)
  -> ((String -> Msg) -> Sub Msg)
  -> Model
  -> Sub Msg
subscriptions tokenRemoved undo redo clipboard model =
  Sub.batch
    [ Window.resizes (\e -> WindowSize (e.width, e.height))
    , Keyboard.downs (KeyCodeMsg True)
    , Keyboard.ups (KeyCodeMsg False)
    , tokenRemoved (always TokenRemoved)
    , undo (always Undo)
    , redo (always Redo)
    , clipboard PasteFromClipboard
    ]


init : Flags -> (Result String URL) -> (Model, Cmd Msg)
init flags urlResult =
  let
    apiConfig =
      { apiRoot = flags.apiRoot
      , accountServiceRoot = flags.accountServiceRoot
      , token = flags.authToken
      } -- TODO

    userState =
      Cache.defaultUserState (if flags.lang == "ja" then JA else EN)

    toModel url =
      Model.init
        apiConfig
        flags.title
        flags.initialSize
        flags.randomSeed
        flags.visitDate
        url.editMode
        (Maybe.withDefault "" url.query)
        userState.scale
        userState.offset
        userState.lang
  in
    case urlResult of
      Ok url ->
        (toModel url)
        ! [ initCmd apiConfig url.editMode userState url.floorId ]

      Err _ ->
        let
          url =
            URL.init

          model =
            toModel url
        in
          model !
            [ initCmd apiConfig url.editMode userState url.floorId
            , Navigation.modifyUrl (URL.stringify "/" url)
            ]


initCmd : API.Config -> Bool -> UserState -> Maybe String -> Cmd Msg
initCmd apiConfig needsEditMode defaultUserState selectedFloor =
  performAPI
    (\(userState, user) -> Initialized selectedFloor needsEditMode userState user)
    ( Cache.getWithDefault Cache.cache defaultUserState `Task.andThen` \userState ->
        API.getAuth apiConfig `Task.andThen` \user ->
        Task.succeed (userState, user)
    )


debug : Bool
debug = False --|| True


debugMsg : Msg -> Msg
debugMsg msg =
  if debug then
    case msg of
      MoveOnCanvas _ -> msg
      _ -> Debug.log "msg" msg
  else
    msg


performAPI : (a -> Msg) -> Task.Task API.Error a -> Cmd Msg
performAPI tagger task =
  Task.perform (Error << APIError) tagger task


saveFloorDebounceConfig : Debounce.Config Msg
saveFloorDebounceConfig =
  { strategy = Debounce.later (1 * second)
  , transform = SaveFloorDebounceMsg
  }


searchCandidateDebounceConfig : Debounce.Config Msg
searchCandidateDebounceConfig =
  { strategy = Debounce.soon (0.4 * second)
  , transform = SearchCandidateDebounceMsg
  }


urlUpdate : Result String URL -> Model -> (Model, Cmd Msg)
urlUpdate result model =
  case result of
    Ok newURL ->
      let
        _ =
          case newURL.floorId of
            Just id ->
              Debug.log ("node server/commands deleteFloor " ++ id) ""

            Nothing ->
              ""
      in
        model ! []

    Err _ ->
      model ! [ Navigation.modifyUrl (URL.stringify "/" URL.init) ]


update : ({} -> Cmd Msg) -> ({} -> Cmd Msg) -> Msg -> Model -> (Model, Cmd Msg)
update removeToken setSelectionStart msg model =
  case debugMsg msg of
    NoOp ->
      model ! []

    Initialized selectedFloor needsEditMode userState user ->
      let
        requestPrivateFloors =
          EditMode.isEditMode model.editMode && not (User.isGuest user)

        searchCmd =
          if String.trim model.searchQuery == "" then
            Cmd.none
          else
            performAPI
              GotSearchResult
              (API.search model.apiConfig requestPrivateFloors model.searchQuery)

        loadFloorCmd =
          case selectedFloor of
            Just floorId ->
              performAPI FloorLoaded (loadFloor model.apiConfig requestPrivateFloors floorId)

            Nothing ->
              Cmd.none

        loadSettingsCmd =
          if User.isGuest user then
            Cmd.none
          else
            Cmd.batch
              [ performAPI ColorsLoaded (API.getColors model.apiConfig)
              , performAPI PrototypesLoaded (API.getPrototypes model.apiConfig)
              ]

        editMode =
          if not (User.isGuest user) then
            if needsEditMode then Select else Viewing False
          else
            Viewing False

        tab =
          if needsEditMode && not (User.isGuest user) then
            EditTab
          else
            SearchTab
      in
        { model |
          user = user
        , scale = userState.scale
        , offset = userState.offset
        , lang = userState.lang
        , editMode = editMode
        , tab = tab
        }
        ! [ searchCmd
          , performAPI FloorsInfoLoaded (API.getFloorsInfo model.apiConfig)
          , loadFloorCmd
          , loadSettingsCmd
          ]

    ColorsLoaded colorPalette ->
      { model | colorPalette = colorPalette } ! []

    PrototypesLoaded prototypeList ->
      { model | prototypes = Prototypes.init prototypeList } ! []

    FloorsInfoLoaded floors ->
      { model | floorsInfo = floors } ! []

    FloorLoaded floor ->
      updateOnFloorLoaded floor model

    ImageSaved url width height ->
      case model.floor of
        Nothing ->
          model ! []

        Just floor ->
          let
            newFloor =
              EditingFloor.update
                (Floor.setImage url width height)
                floor

            saveCmd =
              requestSaveFloorCmd newFloor floor
          in
            { model | floor = Just newFloor } ! [ saveCmd ]

    RequestSave request ->
      let
        (saveFloorDebounce, cmd) =
          Debounce.push
            saveFloorDebounceConfig
            request
            model.saveFloorDebounce
      in
        { model |
          saveFloorDebounce = saveFloorDebounce
        } ! [cmd]

    SaveFloorDebounceMsg msg ->
      let
        save head tail =
          let
            reducedRequests =
              SaveRequest.reduceRequest (head :: tail)
          in
            performAPI FloorSaved (batchSaveFloor model.apiConfig reducedRequests)

        (saveFloorDebounce, cmd) =
          Debounce.update
            saveFloorDebounceConfig
            (Debounce.takeAll save)
            msg
            model.saveFloorDebounce
      in
        { model |
          saveFloorDebounce = saveFloorDebounce
        } ! [cmd]

    FloorSaved dict ->
      let
        (newModel, cmd) =
          dict
            |> Dict.values
            |> List.foldl (\(floor, wasPublish) (model, cmd) ->
              case (wasPublish, model.floor) of
                (False, Just editingFloor) ->
                  -- TODO if id is same
                  ({ model |
                    floor = Just (EditingFloor.changeFloorAfterSave floor editingFloor)
                  }, cmd)

                (True, Just editingFloor) ->
                  let
                    message =
                      Success ("Successfully published " ++ floor.name)

                    newFloor =
                      EditingFloor.changeFloorAfterSave floor editingFloor

                    -- TODO update FloorInfo
                  in
                    { model |
                      floor = Just newFloor
                    , error = message
                    } !
                      [ Task.perform (always NoOp) Error <| (Process.sleep 3000.0 `andThen` \_ -> Task.succeed NoError)
                      ]

                _ ->
                  (model, cmd)
              ) (model, Cmd.none)
      in
        newModel ! [ cmd ]

    FloorDeleted floor ->
      let
        message =
          Success ("Successfully deleted " ++ floor.name)

        -- TODO update FloorInfo
      in
        { model |
          floor = Nothing
        , error = message
        } !
          [ Task.perform (always NoOp) Error <| (Process.sleep 3000.0 `andThen` \_ -> Task.succeed NoError)
          ]

    MoveOnCanvas (clientX, clientY) ->
      let
        (x, y) =
          (clientX, clientY - 37)

        newModel =
          case model.draggingContext of
            Selector ->
              Model.syncSelectedByRect <| Model.updateSelectorRect (x, y) model

            ShiftOffset ->
              Model.updateOffsetByScreenPos (x, y) model

            _ ->
              model
      in
        { newModel |
          pos = (x, y)
        } ! []

    EnterCanvas ->
      model ! []

    LeaveCanvas ->
      { model |
        draggingContext =
          case model.draggingContext of
            ShiftOffset -> NoDragging
            _ -> model.draggingContext
      } ! []

    MouseDownOnObject lastTouchedId (clientX, clientY') ->
      let
        clientY = clientY' - 37

        (model', cmd) =
          if ObjectNameInput.isEditing model.objectNameInput then
            let
              (objectNameInput, ev) =
                ObjectNameInput.forceFinish model.objectNameInput
            in
              case ev of
                Just (id, name) ->
                  updateOnFinishNameInput False id name { model | objectNameInput = objectNameInput }

                Nothing ->
                  { model | objectNameInput = objectNameInput } ! []
          else
            model ! []

        -- TODO
        help model =
          { model |
            pos = (clientX, clientY)
          , selectedObjects =
              if model.keys.ctrl then
                if List.member lastTouchedId model.selectedObjects
                then List.filter ((/=) lastTouchedId) model.selectedObjects
                else lastTouchedId :: model.selectedObjects
              else if model.keys.shift then
                let
                  allObjects =
                    (Model.getEditingFloorOrDummy model).objects
                  objectsExcept target =
                    List.filter (\e -> idOf e /= idOf target) allObjects
                in
                  case (findObjectById allObjects lastTouchedId, Model.primarySelectedObject model) of
                    (Just e, Just primary) ->
                      List.map idOf <|
                        primary :: (withinRange (primary, e) (objectsExcept primary)) --keep primary
                    _ -> [lastTouchedId]
              else
                if List.member lastTouchedId model.selectedObjects
                then model.selectedObjects
                else [lastTouchedId]
          , draggingContext = MoveObject lastTouchedId (clientX, clientY)
          , selectorRect = Nothing
          }
      in
        help model' ! [ cmd, emulateClick lastTouchedId True ]

    MouseUpOnObject lastTouchedId ->
      let
        (newModel, cmd) =
          updateOnMouseUp model
      in
        newModel ! [ cmd, emulateClick lastTouchedId False ]

    MouseUpOnCanvas ->
      let
        (newModel, cmd1) =
          updateOnMouseUp model

        cmd2 =
          Task.perform never (always NoOp) (putUserState newModel)
      in
        newModel ! [ cmd1, cmd2 ]

    MouseDownOnCanvas (clientX, clientY') ->
      let
        clientY = clientY' - 37

        selectorRect =
          case model.editMode of
            Select ->
              let
                (x, y) = fitPositionToGrid model.gridSize <|
                  Model.screenToImageWithOffset model.scale (clientX, clientY) model.offset
              in
                Just (x, y, model.gridSize, model.gridSize)

            _ -> model.selectorRect

        draggingContext =
          case model.editMode of
            LabelMode ->
              NoDragging

            Stamp ->
              StampFromScreenPos (clientX, clientY)

            Pen ->
              PenFromScreenPos (clientX, clientY)

            Select ->
              if model.keys.ctrl then
                Selector
              else
                ShiftOffset

            Viewing _ ->
              ShiftOffset

        (model', cmd) =
          case ObjectNameInput.forceFinish model.objectNameInput of
            (objectNameInput, Just (id, name)) ->
              updateOnFinishNameInput False id name { model | objectNameInput = objectNameInput }

            (objectNameInput, _) ->
              { model | objectNameInput = objectNameInput } ! []

        (model'', cmd2) =
          if model.editMode == LabelMode then
            updateOnFinishLabel model
          else
            (model', Cmd.none)

        newModel =
          { model'' |
            pos = (clientX, clientY)
          , selectedObjects = []
          , selectorRect = selectorRect
          , contextMenu = NoContextMenu
          , draggingContext = draggingContext
          }
      in
        newModel ! [ cmd, cmd2 ]

    MouseDownOnResizeGrip id ->
      let
        (clientX, clientY) =
          model.pos

        (model', cmd) =
          case ObjectNameInput.forceFinish model.objectNameInput of
            (objectNameInput, Just (id, name)) ->
              updateOnFinishNameInput False id name { model | objectNameInput = objectNameInput }

            (objectNameInput, _) ->
              { model | objectNameInput = objectNameInput } ! []

        newModel =
          { model' |
            selectedObjects = []
          , contextMenu = NoContextMenu
          , draggingContext = ResizeFromScreenPos id (clientX, clientY)
          }
      in
        newModel ! [ cmd ]

    StartEditObject id ->
      case findObjectById (Model.getEditingFloorOrDummy model).objects id of
        Just e ->
          let
            (id, name) = (idOf e, nameOf e)

            model' =
              { model |
                selectedResult = Nothing
              , contextMenu = NoContextMenu
              }

            newModel =
              Model.startEdit e model
          in
            newModel !
              [ requestCandidate id name
              -- , Task.perform identity identity (Task.succeed MouseUpOnCanvas) -- TODO get rid of this hack
              , focusCmd
              ]

        Nothing ->
          model ! [] -- [ Task.perform identity identity (Task.succeed MouseUpOnCanvas) ] -- TODO get rid of this hack

    SelectBackgroundColor color ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            newFloor =
              EditingFloor.update
                (Floor.changeObjectBackgroundColor model.selectedObjects color)
                editingFloor

            saveCmd =
              requestSaveFloorCmd newFloor editingFloor
          in
            { model |
              floor = Just newFloor
            } ! [ saveCmd ]

    SelectColor color ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            newFloor =
              EditingFloor.update
                (Floor.changeObjectColor model.selectedObjects color)
                editingFloor

            saveCmd =
              requestSaveFloorCmd newFloor editingFloor
          in
            { model |
              floor = Just newFloor
            } ! [ saveCmd ]

    SelectShape shape ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            newFloor =
              EditingFloor.update
                (Floor.changeObjectShape model.selectedObjects shape)
                editingFloor

            saveCmd =
              requestSaveFloorCmd newFloor editingFloor
          in
            { model |
              floor = Just newFloor
            } ! [ saveCmd ]

    SelectFontSize fontSize ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            newFloor =
              EditingFloor.update
                (Floor.changeObjectFontSize model.selectedObjects fontSize)
                editingFloor

            saveCmd =
              requestSaveFloorCmd newFloor editingFloor
          in
            { model |
              floor = Just newFloor
            } ! [ saveCmd ]

    ObjectNameInputMsg message ->
      let
        (objectNameInput, event) =
          ObjectNameInput.update message model.objectNameInput

        model' =
          { model |
            objectNameInput = objectNameInput
          }
      in
        case event of
          ObjectNameInput.OnInput id name ->
            model' ! [ requestCandidate id name ]

          ObjectNameInput.OnFinish objectId name candidateId ->
            case candidateId of
              Just personId ->
                updateOnSelectCandidate objectId personId model'

              Nothing ->
                updateOnFinishNameInput True objectId name model'

          ObjectNameInput.OnSelectCandidate objectId personId ->
            updateOnSelectCandidate objectId personId model'

          ObjectNameInput.OnUnsetPerson objectId ->
            case model'.floor of
              Nothing ->
                model' ! []

              Just editingFloor ->
                let
                  newFloor =
                    EditingFloor.update
                      (Floor.unsetPerson objectId)
                      editingFloor

                  saveCmd =
                    requestSaveFloorCmd newFloor editingFloor
                in
                  { model' |
                    floor = Just newFloor
                  } ! [ saveCmd ]

          ObjectNameInput.None ->
            model' ! []

    RequestCandidate objectId name ->
      let
        (searchCandidateDebounce, cmd) =
          Debounce.push
            searchCandidateDebounceConfig
            (objectId, name)
            model.searchCandidateDebounce
      in
        { model |
          searchCandidateDebounce = searchCandidateDebounce
        } ! [ cmd ]

    SearchCandidateDebounceMsg msg ->
      let
        search (objectId, name) =
          performAPI
            (GotCandidateSelection objectId)
            (API.personCandidate model.apiConfig name)

        (searchCandidateDebounce, cmd) =
          Debounce.update
            searchCandidateDebounceConfig
            (Debounce.takeLast search)
            msg
            model.searchCandidateDebounce
      in
        { model |
          searchCandidateDebounce = searchCandidateDebounce
        } ! [ cmd ]

    GotCandidateSelection objectId people ->
      { model |
        personInfo =
          DictUtil.addAll (.id) people model.personInfo
      , candidates = List.map .id people
      } ! []

    GotMatchingList pairs ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            matchedPairs =
              List.filterMap (\(objectId, people) ->
                case people of
                  -- determined
                  [person] ->
                    Just (objectId, person.id)

                  _ ->
                    Nothing
                ) pairs

            newFloor =
              EditingFloor.update
                (Floor.setPeople matchedPairs)
                editingFloor

            saveCmd =
              requestSaveFloorCmd newFloor editingFloor

            allPeople =
              List.concatMap snd pairs

            personInfo =
              DictUtil.addAll (.id) allPeople model.personInfo
          in
            { model |
              floor = Just newFloor
            , personInfo = personInfo
            } ! [ saveCmd ]

    ShowContextMenuOnObject id ->
      let
        selectedObjects =
          if List.member id model.selectedObjects then
            model.selectedObjects
          else
            [id]

        maybeLoadPersonCmd =
          model.floor `Maybe.andThen` \eFloor ->
          ObjectsOperation.findObjectById (EditingFloor.present eFloor).objects id `Maybe.andThen` \obj ->
          Object.relatedPerson obj `Maybe.andThen` \personId ->
          Just (getAndCachePersonIfNotCached personId model)

        cmd =
          Maybe.withDefault Cmd.none maybeLoadPersonCmd
      in
        { model |
          contextMenu = Model.Object model.pos id
        , selectedObjects = selectedObjects
        } ! [ cmd ]

    ShowContextMenuOnFloorInfo id ->
      case model.floor of
        Just editingFloor ->
          { model |
            contextMenu =
              -- TODO idealy, change floor and show context menu
              if (EditingFloor.present editingFloor).id == id then
                FloorInfo model.pos id
              else
                NoContextMenu
          } ! []

        Nothing ->
          model ! []


    GoToFloor floorId requestLastEdit ->
      let
        loadCmd =
          if String.length floorId > 0 then
            performAPI FloorLoaded (loadFloor model.apiConfig requestLastEdit floorId)
          else
            Cmd.none

        newModel =
          { model |
            contextMenu = NoContextMenu
          }
    in
      newModel !
        [ loadCmd
        , Navigation.modifyUrl (URL.serialize newModel)
        ]

    SelectSamePost personId ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            floor =
              EditingFloor.present editingFloor

            cmd =
              performAPI
                GotSamePostPeople
                ( API.getPeopleByFloorAndPost
                    model.apiConfig
                    floor.id
                    editingFloor.version
                    personId
                )

            newModel =
              { model |
                contextMenu = NoContextMenu
              }
          in
            newModel ! [ cmd ]

    SearchSamePost postName ->
      submitSearch
        { model
        | searchQuery = postName
        , tab = SearchTab
        , contextMenu = NoContextMenu
        }

    GotSamePostPeople people ->
      let
        personIds =
          List.map .id people

        newSelectedObjects =
          List.filterMap (\obj ->
            case Object.relatedPerson obj of
              Just personId ->
                if List.member personId personIds then
                  Just (idOf obj)
                else
                  Nothing

              Nothing ->
                Nothing
          ) (Model.getEditingFloorOrDummy model).objects

        newModel =
          { model |
            selectedObjects = newSelectedObjects
          } |> Model.registerPeople people
      in
        newModel ! []

    SelectIsland id ->
      case model.floor of
        Just editingFloor ->
          let
            floor =
              EditingFloor.present editingFloor

            newModel =
              case findObjectById floor.objects id of
                Just object ->
                  let
                    island' =
                      island
                        [object]
                        (List.filter (\e -> (idOf e) /= id) floor.objects)
                  in
                    { model |
                      selectedObjects = List.map idOf island'
                    , contextMenu = NoContextMenu
                    }

                Nothing ->
                  model
          in
            newModel ! []

        Nothing ->
          model ! []

    SelectSameColor id ->
      case model.floor of
        Just editingFloor ->
          let
            floor =
              EditingFloor.present editingFloor

            newModel =
              case findObjectById floor.objects id of
                Just object ->
                  let
                    target =
                      List.filter
                        (\e -> (backgroundColorOf e) == (backgroundColorOf object))
                        floor.objects
                  in
                    { model |
                      selectedObjects = List.map idOf target
                    , contextMenu = NoContextMenu
                    }

                Nothing ->
                  model
          in
            newModel ! []

        Nothing ->
          model ! []

    KeyCodeMsg isDown keyCode ->
      let
        (keys, event) =
          ShortCut.update isDown keyCode model.keys

        model' =
          { model | keys = keys }
      in
        updateByKeyEvent event model'

    MouseWheel value ->
      let
        (clientX, clientY) =
          model.pos

        newScale =
          if value < 0 then
            Scale.update Scale.ScaleUp model.scale
          else
            Scale.update Scale.ScaleDown model.scale

        ratio =
          Scale.ratio model.scale newScale

        (offsetX, offsetY) =
          model.offset

        newOffset =
          let
            x = Scale.screenToImage model.scale clientX
            y = Scale.screenToImage model.scale (clientY - 37) --TODO header hight
          in
            ( floor (toFloat (x - floor (ratio * (toFloat (x - offsetX)))) / ratio)
            , floor (toFloat (y - floor (ratio * (toFloat (y - offsetY)))) / ratio)
            )

        newModel =
          { model |
            scale = newScale
          , offset = newOffset
          , scaling = True
          }

        saveUserStateCmd =
          Task.perform never (always NoOp) (putUserState newModel)

        cmd =
          Task.perform (always NoOp) (always ScaleEnd) (Process.sleep 200.0)
      in
        newModel ! [ saveUserStateCmd, cmd ]

    ScaleEnd ->
        { model | scaling = False } ! []

    WindowSize (w, h) ->
        { model | windowSize = (w, h) } ! []

    ChangeMode mode ->
        { model | editMode = mode } ! []

    PrototypesMsg msg ->
      let
        newModel =
          { model |
            prototypes = Prototypes.update msg model.prototypes
          , editMode = Stamp -- TODO if event == select
          }
      in
        newModel ! []

    RegisterPrototype id ->
      let
        object =
          findObjectById (Model.getEditingFloorOrDummy model).objects id

        model' =
          { model |
            contextMenu = NoContextMenu
          }
      in
        case object of
          Just e ->
            let
              (_, _, w, h) = rect e

              (newId, seed) = IdGenerator.new model.seed

              newPrototypes =
                Prototypes.register
                  { id = newId
                  , color = colorOf e
                  , backgroundColor = backgroundColorOf e
                  , name = nameOf e
                  , size = (w, h)
                  , fontSize = fontSizeOf e
                  , shape = shapeOf e
                  }
                  model.prototypes
            in
              { model' |
                seed = seed
              , prototypes = newPrototypes
              } ! [ (savePrototypesCmd model.apiConfig) newPrototypes.data ]

          Nothing ->
            model' ! []

    FloorPropertyMsg message ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            (floorProperty, cmd1, event) =
              FloorProperty.update message model.floorProperty

            ((newFloor, newSeed), cmd2) =
              updateFloorByFloorPropertyEvent model.apiConfig event model.seed editingFloor

            newModel =
              { model |
                floor = Just newFloor
              , floorProperty = floorProperty
              , seed = newSeed
              }
          in
            newModel ! [ Cmd.map FloorPropertyMsg cmd1, cmd2 ]

    Rotate id ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            newFloor =
              EditingFloor.update
                (Floor.rotateObject id)
                editingFloor

            saveCmd =
              requestSaveFloorCmd newFloor editingFloor
          in
            { model |
              floor = Just newFloor
            , contextMenu = NoContextMenu
            } ! [ saveCmd ]

    FirstNameOnly ids ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            newFloor =
              EditingFloor.update
                (Floor.toFirstNameOnly ids)
                editingFloor

            saveCmd =
              requestSaveFloorCmd newFloor editingFloor
          in
            { model |
              floor = Just newFloor
            , contextMenu = NoContextMenu
            } ! [ saveCmd ]

    RemoveSpaces ids ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            newFloor =
              EditingFloor.update (Floor.removeSpaces ids) editingFloor

            saveCmd =
              requestSaveFloorCmd newFloor editingFloor
          in
            { model |
              floor = Just newFloor
            , contextMenu = NoContextMenu
            } ! [ saveCmd ]

    UpdateHeaderState msg ->
      { model | headerState = Header.update msg model.headerState } ! []

    SignIn ->
      model ! [ Task.perform (always NoOp) (always NoOp) API.goToLogin ]

    SignOut ->
      model ! [ removeToken {} ]

    ToggleEditing ->
      let
        newModel =
          { model |
            editMode =
              case model.editMode of
                Viewing _ -> Select
                _ -> Viewing False

          , tab =
              case model.editMode of
                Viewing _ -> EditTab
                _ -> SearchTab
          }

        withPrivate =
          EditMode.isEditMode newModel.editMode && not (User.isGuest newModel.user)

        loadFloorCmd =
          case model.floor of
            Just floor ->
              let
                floorId =
                  (EditingFloor.present floor).id
              in
                performAPI FloorLoaded (loadFloor model.apiConfig withPrivate floorId)

            Nothing ->
              Cmd.none
      in
        newModel !
          [ loadFloorCmd
          , Navigation.modifyUrl (URL.serialize newModel)
          ]

    TogglePrintView prevEditMode ->
      { model |
        editMode = prevEditMode
      } ! []

    SelectLang lang ->
      let
        newModel =
          { model | lang = lang }
      in
        newModel ! [ Task.perform never (always NoOp) (putUserState newModel) ]

    UpdateSearchQuery searchQuery ->
      { model |
        searchQuery = searchQuery
      } ! []

    SubmitSearch ->
      submitSearch model

    GotSearchResult results ->
      let
        regesterPersonCmd =
          Cmd.batch <|
          List.filterMap (\r ->
            case r.personId of
              Just id -> Just (regesterPersonIfNotCached model.apiConfig model.personInfo id)
              Nothing -> Nothing
          ) results

        selectedResult =
          case results of
            { objectIdAndFloorId } :: [] ->
              case objectIdAndFloorId of
                Just (e, fid) ->
                  Just (idOf e)

                Nothing ->
                  Nothing

            _ -> Nothing

        searchResult =
          Just <|
            SearchResult.reorderResults
              (Maybe.map (\floor -> (EditingFloor.present floor).id) model.floor)
              results
      in
        { model |
          searchResult = searchResult
        , selectedResult = selectedResult
        } ! [ regesterPersonCmd ]

    SelectSearchResult { personId, objectIdAndFloorId } ->
      let
        (newModel, cmd1) =
          case objectIdAndFloorId of
            Just (obj, floorId) ->
              let
                model' =
                  Model.adjustOffset
                    { model |
                      selectedResult = Just (idOf obj)
                    }

                requestPrivateFloors =
                  EditMode.isEditMode model'.editMode && not (User.isGuest model'.user)
              in
                model' !
                  [ performAPI FloorLoaded (loadFloor model'.apiConfig requestPrivateFloors floorId)
                  , Navigation.modifyUrl (URL.serialize model')
                  ]

            Nothing ->
              (model, Cmd.none)

        cmd2 =
          case personId of
            Just id -> regesterPersonIfNotCached model.apiConfig model.personInfo id
            Nothing -> Cmd.none
      in
        newModel ! [cmd1, cmd2]

    StartDraggingFromMissingPerson personId ->
      { model |
        contextMenu = NoContextMenu
      , draggingContext = MoveFromSearchResult
      } ! []

    RegisterPeople people ->
      Model.registerPeople people model ! []

    UpdatePersonCandidate objectId personIds ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          case personIds of
            head :: [] ->
              let
                newFloor =
                  EditingFloor.update
                    (Floor.setPerson objectId head)
                    editingFloor

                saveCmd =
                  requestSaveFloorCmd newFloor editingFloor
              in
                { model |
                  floor = Just newFloor
                } ! [ saveCmd ]

            _ ->
              model ! []

    GotDiffSource diffSource ->
      { model | diff = Just diffSource } ! []

    CloseDiff ->
      { model | diff = Nothing } ! []

    ConfirmDiff ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            cmd =
              requestPublishFloorCmd (EditingFloor.present editingFloor).id
          in
            { model |
              diff = Nothing
            } ! [ cmd ]

    ChangeTab tab ->
      { model | tab = tab } ! []

    ClosePopup ->
      { model | selectedResult = Nothing } ! []

    ShowDetailForObject id ->
      let
        allObjects =
          (Model.getEditingFloorOrDummy model).objects

        personId =
          case findObjectById allObjects id of
            Just e ->
              relatedPerson e

            Nothing ->
              Nothing

        cmd =
          case personId of
            Just id -> regesterPerson model.apiConfig id
            Nothing -> Cmd.none
      in
        ({ model |
          selectedResult = Just id
        } |> Model.adjustOffset
        ) ! [ cmd ]

    CreateNewFloor ->
      let
        (newFloorId, newSeed) =
          IdGenerator.new model.seed

        lastFloorOrder =
          case List.drop (List.length model.floorsInfo - 1) model.floorsInfo of
            [] ->
              0
            x :: _ ->
              case x of
                FloorInfo.Public floor ->
                  floor.ord
                FloorInfo.PublicWithEdit publicFloor editingFloor ->
                  editingFloor.ord
                FloorInfo.Private floor ->
                  floor.ord

        newFloor =
          Floor.initWithOrder newFloorId lastFloorOrder

        cmd =
          performAPI
            (FloorLoaded << Just)
            (API.saveEditingFloor model.apiConfig newFloor (snd <| FloorDiff.diff newFloor Nothing))

        newModel =
          { model | seed = newSeed }
      in
        newModel !
          [ cmd
          , Navigation.modifyUrl (URL.serialize newModel)
          ]

    CopyFloor id ->
      let
        (newFloorId, newSeed) =
          IdGenerator.new model.seed

        newFloor =
          Floor.copy newFloorId (Model.getEditingFloorOrDummy model)

        saveCmd =
          performAPI
            (FloorLoaded << Just)
            (API.saveEditingFloor model.apiConfig newFloor (snd <| FloorDiff.diff newFloor Nothing))

        newModel =
          { model |
            seed = newSeed
          , floor = Just (EditingFloor.init newFloor)
          , contextMenu = NoContextMenu
          }

      in
        newModel !
          [ saveCmd
          , Navigation.modifyUrl (URL.serialize newModel)
          ]

    EmulateClick id down time ->
      let
        (clickEmulator, event) =
          case (id, down, time) :: model.clickEmulator of
            (id4, False, time4) :: (id3, True, time3) :: (id2, False, time2) :: (id1, True, time1) :: _ ->
              if List.all ((==) id1) [id2, id3, id4] && (time4 - time1 < 400) then
                ([], "dblclick")
              else
                (List.take 4 <| (id, down, time) :: model.clickEmulator, "")
            _ ->
              (List.take 4 <| (id, down, time) :: model.clickEmulator, "")
      in
        { model | clickEmulator = clickEmulator }
        ! ( if event == "dblclick" then
              [ Task.perform identity identity (Task.succeed (StartEditObject id)) ]
            else
              []
            )

    TokenRemoved ->
      { model |
        user = User.guest
      , tab = SearchTab
      , editMode = Viewing False
      } ! []

    Undo ->
      case model.floor of
        Nothing ->
          model ! []

        Just floor ->
          let
            newFloor =
              EditingFloor.undo floor

            saveCmd =
              requestSaveFloorCmd newFloor floor
          in
            { model | floor = Just newFloor } ! [ saveCmd ]

    Redo ->
      case model.floor of
        Nothing ->
          model ! []

        Just floor ->
          let
            newFloor =
              EditingFloor.redo floor

            saveCmd =
              requestSaveFloorCmd newFloor floor
          in
            { model | floor = Just newFloor } ! [ saveCmd ]

    Focused ->
      model ! [ setSelectionStart {} ]

    PasteFromClipboard s ->
      case (model.floor, model.selectorRect) of
        (Just floor, Just (left, top, _, _)) ->
          let
            prototype =
              Prototypes.selectedPrototype model.prototypes

            candidates =
              ClickboardData.toObjectCandidates prototype (left, top) s

            ((newModel, cmd), newIdNamePairs) =
              updateOnFinishStamp' candidates model floor

            task =
              List.foldl
                (\(objectId, name) prevTask ->
                  prevTask `andThen` \list ->
                    Task.map (\people ->
                      (objectId, people) :: list
                    ) (API.personCandidate model.apiConfig name)
                ) (Task.succeed []) newIdNamePairs

            autoMatchingCmd =
              performAPI GotMatchingList task
          in
            { newModel |
              selectedObjects = List.map fst newIdNamePairs
            } ! [ cmd, autoMatchingCmd ]

        _ ->
          model ! []

    SyncFloor ->
      case model.floor of
        Just editingFloor ->
          let
            requestPrivateFloors =
              EditMode.isEditMode model.editMode && not (User.isGuest model.user)

            floorId =
              (EditingFloor.present editingFloor).id

            loadFloorCmd =
              performAPI FloorLoaded (loadFloor model.apiConfig requestPrivateFloors floorId)
          in
            model !
              [ loadFloorCmd ]

        _ ->
          model ! []

    Error e ->
      let
        newModel =
          { model | error = e }
      in
        newModel ! []


submitSearch : Model -> (Model, Cmd Msg)
submitSearch model =
  let
    withPrivate =
      not (User.isGuest model.user)

    -- TODO dedup
    searchCmd =
      if String.trim model.searchQuery == "" then
        Cmd.none
      else
        performAPI
          GotSearchResult
          (API.search model.apiConfig withPrivate model.searchQuery)
  in
    model !
      [ searchCmd, Navigation.modifyUrl (URL.serialize model) ]


updateOnMouseUp : Model -> (Model, Cmd Msg)
updateOnMouseUp model =
  let
    (clientX, clientY) =
      model.pos

    (model', cmd) =
      case model.draggingContext of
        MoveObject id (x, y) ->
          updateByMoveObjectEnd id (x, y) (clientX, clientY) model

        Selector ->
          -- (updateSelectorRect (clientX, clientY) model) ! []
          { model | selectorRect = Nothing } ! []

        StampFromScreenPos _ ->
          updateOnFinishStamp model

        PenFromScreenPos pos ->
          updateOnFinishPen pos model

        ResizeFromScreenPos id pos ->
          updateOnFinishResize id pos model

        _ ->
          model ! []

    newModel =
      { model' |
        draggingContext = NoDragging
      }
  in
    newModel ! [ cmd ]


updateOnSelectCandidate : Id -> String -> Model -> (Model, Cmd Msg)
updateOnSelectCandidate objectId personId model =
  case (model.floor, Dict.get personId model.personInfo) of
    (Just floor, Just person) ->
      let
        newFloor =
          EditingFloor.update
            (Floor.setPerson objectId personId)
            floor
      in
        updateOnFinishNameInput True objectId person.name
          { model |
            floor = Just newFloor
          }

    _ ->
      model ! []


requestCandidate : Id -> String -> Cmd Msg
requestCandidate id name =
  Task.perform identity identity <| Task.succeed (RequestCandidate id name)


emulateClick : String -> Bool -> Cmd Msg
emulateClick id down =
  Task.perform identity identity <|
  Time.now `Task.andThen` \time ->
  (Task.succeed (EmulateClick id down time))


updateOnFinishStamp : Model -> (Model, Cmd Msg)
updateOnFinishStamp model =
  case model.floor of
    Just floor ->
      fst <| updateOnFinishStamp' (Model.stampCandidates model) model floor

    Nothing ->
      model ! []


updateOnFinishStamp' : List StampCandidate -> Model -> EditingFloor -> ((Model, Cmd Msg), List (Id, String))
updateOnFinishStamp' stampCandidates model floor =
  let
    (candidatesWithNewIds, newSeed) =
      IdGenerator.zipWithNewIds model.seed stampCandidates

    newIdNamePairs =
      List.map
        (\((prototype, _), newId) ->
          (newId, prototype.name)
        )
        candidatesWithNewIds

    newObjects =
      List.map
        (\((prototype, (x, y)), newId) ->
          let
            (width, height) = prototype.size
          in
            Object.initDesk newId (x, y, width, height) prototype.backgroundColor prototype.name prototype.fontSize Nothing
        )
        candidatesWithNewIds

    newFloor =
      EditingFloor.update (Floor.addObjects newObjects) floor

    saveCmd =
      requestSaveFloorCmd newFloor floor
  in
    (({ model |
      seed = newSeed
    , floor = Just newFloor
    , editMode = Select -- maybe selecting stamped desks would be better?
    }, saveCmd), newIdNamePairs)


updateOnFinishPen : (Int, Int) -> Model -> (Model, Cmd Msg)
updateOnFinishPen (x, y) model =
  case (model.floor, Model.temporaryPen model (x, y)) of
    (Just floor, Just (color, name, (left, top, width, height))) ->
      let
        (newId, newSeed) =
          IdGenerator.new model.seed

        newFloor =
          EditingFloor.update
            (Floor.addObjects [ Object.initDesk newId (left, top, width, height) color name Object.defaultFontSize Nothing ])
            floor

        saveCmd =
          requestSaveFloorCmd newFloor floor
      in
        { model |
          seed = newSeed
        , floor = Just newFloor
        } ! [ saveCmd ]

    _ ->
      model ! []


updateOnFinishResize : Id -> (Int, Int) -> Model -> (Model, Cmd Msg)
updateOnFinishResize id (x, y) model =
  model.floor
    |> (flip Maybe.andThen) (\editingFloor -> findObjectById (EditingFloor.present editingFloor).objects id
    |> (flip Maybe.andThen) (\e -> Model.temporaryResizeRect model (x, y) (rect e)
    |> Maybe.map (\(_, _, width, height) ->
        let
          newFloor =
            EditingFloor.update (Floor.resizeObject id (width, height)) editingFloor

          saveCmd =
            requestSaveFloorCmd newFloor editingFloor
        in
          { model | floor = Just newFloor } ! [ saveCmd ]
      )))
    |> Maybe.withDefault (model ! [])


updateOnFinishLabel : Model -> (Model, Cmd Msg)
updateOnFinishLabel model =
  case model.floor of
    Just floor ->
      let
        (left, top) =
          fitPositionToGrid model.gridSize <|
            Model.screenToImageWithOffset model.scale model.pos model.offset

        (width, height) =
          fitSizeToGrid model.gridSize (100, 100) -- TODO configure?

        bgColor = "transparent" -- TODO configure?

        color = "#000"

        name = ""

        fontSize = 40 -- TODO

        (newId, newSeed) =
          IdGenerator.new model.seed

        newFloor =
          EditingFloor.update
            (Floor.addObjects [ Object.initLabel newId (left, top, width, height) bgColor name fontSize color Object.Rectangle])
            floor

        saveCmd =
          requestSaveFloorCmd newFloor floor

        model' =
          { model |
            seed = newSeed
          , editMode = Select
          , floor = Just newFloor
          }
      in
        case findObjectById (EditingFloor.present newFloor).objects newId of
          Just e ->
            let
              newModel =
                Model.startEdit e model'
            in
              newModel ! [ saveCmd, focusCmd ]

          Nothing ->
            model' ! [ saveCmd ]

    _ ->
      model ! []


updateOnFloorLoaded : Maybe Floor -> Model -> (Model, Cmd Msg)
updateOnFloorLoaded maybeFloor model =
  case maybeFloor of
    Just floor ->
      let
        (realWidth, realHeight) =
          Floor.realSize floor

        newModel =
          Model.adjustOffset
            { model |
              floorsInfo = FloorInfo.addNewFloor (Floor.baseOf floor) model.floorsInfo -- TODO ?
            , floor = Just (EditingFloor.init floor)
            , floorProperty = FloorProperty.init floor.name realWidth realHeight floor.ord
            }

        cmd =
          case (User.isGuest model.user, floor.update) of
            (False, Just { by }) ->
              getAndCachePersonIfNotCached by model

            _ ->
              Cmd.none
      in
        newModel ! [ cmd, Navigation.modifyUrl (URL.serialize newModel) ]

    Nothing ->
      let
        newModel =
          { model | floor = Nothing }
      in
        newModel ! [ Navigation.modifyUrl (URL.serialize newModel) ]


getAndCachePersonIfNotCached : String -> Model -> Cmd Msg
getAndCachePersonIfNotCached personId model =
  case Dict.get personId model.personInfo of
    Just _ ->
      Cmd.none

    Nothing ->
      performAPI
        (\person -> RegisterPeople [person])
        (API.getPersonByUser model.apiConfig personId)


focusCmd : Cmd Msg
focusCmd =
  Task.perform (always NoOp) (always Focused) (Dom.focus "name-input")


updateFloorByFloorPropertyEvent : API.Config -> FloorProperty.Event -> Seed -> EditingFloor -> ((EditingFloor, Seed), Cmd Msg)
updateFloorByFloorPropertyEvent apiConfig event seed efloor =
  case event of
    FloorProperty.None ->
      (efloor, seed) ! []

    FloorProperty.OnNameChange name ->
      let
        newFloor =
          EditingFloor.update (Floor.changeName name) efloor

        saveCmd =
          requestSaveFloorCmd newFloor efloor
      in
        (newFloor, seed) ! [ saveCmd ]

    FloorProperty.OnOrdChange ord ->
      let
        newFloor =
          EditingFloor.update (Floor.changeOrd ord) efloor

        saveCmd =
          requestSaveFloorCmd newFloor efloor
      in
        (newFloor, seed) ! [ saveCmd ]

    FloorProperty.OnRealSizeChange (w, h) ->
      let
        newFloor =
          EditingFloor.update (Floor.changeRealSize (w, h)) efloor

        saveCmd =
          requestSaveFloorCmd newFloor efloor
      in
        (newFloor, seed) ! [ saveCmd ]

    FloorProperty.OnFileWithDataURL file dataURL ->
      let
        (id, newSeed) =
          IdGenerator.new seed

        url = id

        (width, height) =
          getSizeOfImage dataURL

        saveImageCmd =
          performAPI
            (always <| ImageSaved url width height)
            (API.saveEditingImage apiConfig url file)
      in
        (efloor, newSeed) ! [ saveImageCmd ]

    FloorProperty.OnPreparePublish ->
      let
        cmd =
          performAPI GotDiffSource (API.getDiffSource apiConfig (EditingFloor.present efloor).id)
      in
        (efloor, seed) ! [ cmd ]

    FloorProperty.OnDeleteFloor ->
      let
        floor =
          EditingFloor.present efloor

        cmd =
          performAPI (\_ -> FloorDeleted floor) (API.deleteEditingFloor apiConfig floor.id)
      in
        (efloor, seed) ! [ cmd ]

    FloorProperty.OnFileLoadFailed err ->
      let
        cmd =
          Task.perform (Error << FileError) (always NoOp) (Task.fail err)
      in
        (efloor, seed) ! [ cmd ]


regesterPersonOfObject : API.Config -> Object -> Cmd Msg
regesterPersonOfObject apiConfig e =
  case Object.relatedPerson e of
    Just personId ->
      regesterPerson apiConfig personId

    Nothing ->
      Cmd.none


regesterPerson : API.Config -> String -> Cmd Msg
regesterPerson apiConfig personId =
  performAPI identity <|
    API.getPerson apiConfig personId `andThen` \person ->
      Task.succeed (RegisterPeople [person])


regesterPersonIfNotCached : API.Config -> Dict String Person -> String -> Cmd Msg
regesterPersonIfNotCached apiConfig personInfo personId =
  if Dict.member personId personInfo then
    Cmd.none
  else
    regesterPerson apiConfig personId


updateOnFinishNameInput : Bool -> String -> String -> Model -> (Model, Cmd Msg)
updateOnFinishNameInput continueEditing id name model =
  case model.floor of
    Nothing ->
      model ! []

    Just floor ->
      let
        allObjects = (EditingFloor.present floor).objects

        (objectNameInput, requestCandidateCmd) =
          case findObjectById allObjects id of
            Just object ->
              if continueEditing then
                case nextObjectToInput object allObjects of
                  Just e ->
                    ( ObjectNameInput.start (idOf e, nameOf e) model.objectNameInput
                    , requestCandidate (idOf e) (nameOf e)
                    )

                  Nothing ->
                    ( model.objectNameInput
                    , requestCandidate id name
                    )
              else
                (model.objectNameInput, Cmd.none)

            Nothing ->
              (model.objectNameInput, Cmd.none)

        registerPersonDetailCmd =
          case findObjectById allObjects id of
            Just object ->
              registerPersonDetailIfAPersonIsNotRelatedTo model.apiConfig object

            Nothing ->
              Cmd.none

        selectedObjects =
          case objectNameInput.editingObject of
            Just (id, _) ->
              [id]

            Nothing ->
              []

        newFloor =
          EditingFloor.update
            (Floor.changeObjectName [id] name)
            floor

        saveCmd =
          requestSaveFloorCmd newFloor floor

        newModel =
          { model |
            floor = Just newFloor
          , objectNameInput = objectNameInput
          , candidates = []
          , selectedObjects = selectedObjects
          }
      in
        newModel ! [ requestCandidateCmd, registerPersonDetailCmd, saveCmd, focusCmd ]


registerPersonDetailIfAPersonIsNotRelatedTo : API.Config -> Object -> Cmd Msg
registerPersonDetailIfAPersonIsNotRelatedTo apiConfig object =
  case Object.relatedPerson object of
    Just personId ->
      Cmd.none

    Nothing ->
      let
        task =
          API.personCandidate apiConfig (nameOf object)
      in
        performAPI RegisterPeople task


nextObjectToInput : Object -> List Object -> Maybe Object
nextObjectToInput object allObjects =
  let
    island' =
      island
        [object]
        (List.filter (\e -> (idOf e) /= (idOf object)) allObjects)
  in
    case ObjectsOperation.nearest Down object island' of
      Just e ->
        if idOf object == idOf e then
          Nothing
        else
          Just e

      _ ->
        Nothing


savePrototypesCmd : API.Config -> List Prototype -> Cmd Msg
savePrototypesCmd apiConfig prototypes =
  performAPI
    (always NoOp)
    (API.savePrototypes apiConfig prototypes)


requestSaveFloorCmd : EditingFloor -> EditingFloor -> Cmd Msg
requestSaveFloorCmd efloor oldFloor =
  requestCmd (SaveFloor efloor.version (EditingFloor.present efloor) (EditingFloor.present oldFloor))


requestPublishFloorCmd : String -> Cmd Msg
requestPublishFloorCmd id =
  requestCmd (PublishFloor id)


requestCmd : SaveRequest -> Cmd Msg
requestCmd req =
  Task.perform identity identity (Task.succeed (RequestSave req))


batchSaveFloor : API.Config -> List SaveRequestOpt -> Task Http.Error (Dict String (Floor, Bool))
batchSaveFloor apiConfig requests =
  List.foldr
    (\req prevTask ->
      prevTask `Task.andThen` \prevFloors ->
        let
          task =
            case req of
              SaveFloorOpt floor version change ->
                API.saveEditingFloor apiConfig { floor | version = version } change
                  |> Task.map (\floor -> (floor, False))

              PublishFloorOpt id ->
                API.publishEditingFloor apiConfig id
                  |> Task.map (\floor -> (floor, True))
        in
          task
            |> Task.map (\(floor, wasPublish) -> Dict.insert floor.id (floor, wasPublish) prevFloors)
      ) (Task.succeed Dict.empty) requests


updateByKeyEvent : ShortCut.Event -> Model -> (Model, Cmd Msg)
updateByKeyEvent event model =
  case (model.floor, model.keys.ctrl, event) of
    (Just floor, True, ShortCut.A) ->
      { model |
        selectedObjects =
          List.map idOf <| Floor.objects (Model.getEditingFloorOrDummy model)
      } ! []

    (Just floor, True, ShortCut.C) ->
      { model |
        copiedObjects = Model.selectedObjects model
      } ! []

    (Just floor, True, ShortCut.V) ->
      let
        base =
          case model.selectorRect of
            Just (x, y, w, h) ->
              (x, y)

            Nothing -> (0, 0) --TODO

        (copiedIdsWithNewIds, newSeed) =
          IdGenerator.zipWithNewIds model.seed model.copiedObjects

        newFloor =
          EditingFloor.update (Floor.paste copiedIdsWithNewIds base) floor

        saveCmd =
          requestSaveFloorCmd newFloor floor
      in
        { model |
          floor = Just newFloor
        , seed = newSeed
        , selectedObjects =
          case List.map snd copiedIdsWithNewIds of
            [] -> model.selectedObjects -- for pasting from spreadsheet
            x -> x
        , selectorRect = Nothing
        } ! [ saveCmd ]

    (Just floor, True, ShortCut.X) ->
      let
        newFloor =
          EditingFloor.update (Floor.delete model.selectedObjects) floor

        saveCmd =
          requestSaveFloorCmd newFloor floor
      in
        { model |
          floor = Just newFloor
        , copiedObjects = Model.selectedObjects model
        , selectedObjects = []
        } ! [ saveCmd ]

    (Just floor, _, ShortCut.UpArrow) ->
      moveSelectionToward Up model floor

    (Just floor, _, ShortCut.DownArrow) ->
      moveSelectionToward Down model floor

    (Just floor, _, ShortCut.LeftArrow) ->
      moveSelectionToward Left model floor

    (Just floor, _, ShortCut.RightArrow) ->
      moveSelectionToward Right model floor

    (Just floor, _, ShortCut.Del) ->
      let
        newFloor =
          EditingFloor.update (Floor.delete model.selectedObjects) floor

        saveCmd =
          requestSaveFloorCmd newFloor floor
      in
        { model |
          floor = Just newFloor
        } ! [ saveCmd ]

    (Just floor, _, ShortCut.Other 9) ->
      Model.shiftSelectionToward Right model ! []

    _ ->
      model ! []


moveSelectionToward : Direction -> Model -> EditingFloor -> (Model, Cmd Msg)
moveSelectionToward direction model editingFloor =
  let
    shift =
      Direction.shiftTowards direction model.gridSize

    newFloor =
      EditingFloor.update
        (Floor.move model.selectedObjects model.gridSize shift)
        editingFloor

    saveCmd =
      requestSaveFloorCmd newFloor editingFloor
  in
    { model |
      floor = Just newFloor
    } ! [ saveCmd ]


updateByMoveObjectEnd : Id -> (Int, Int) -> (Int, Int) -> Model -> (Model, Cmd Msg)
updateByMoveObjectEnd id (x0, y0) (x1, y1) model =
  case model.floor of
    Nothing ->
      model ! []

    Just floor ->
      let
        shift =
          Scale.screenToImageForPosition model.scale (x1 - x0, y1 - y0)
      in
        if shift /= (0, 0) then
          let
            newFloor =
              EditingFloor.update
                (Floor.move model.selectedObjects model.gridSize shift)
                floor

            saveCmd =
              requestSaveFloorCmd newFloor floor
          in
            { model |
              floor = Just newFloor
            } ! [ saveCmd ]
        -- comment out for contextmenu
        -- else if not model.keys.ctrl && not model.keys.shift then
        --   { model |
        --     selectedObjects = [id]
        --   } ! []
        else
          model ! []


putUserState : Model -> Task x ()
putUserState model =
  Cache.put model.cache { scale = model.scale, offset = model.offset, lang = model.lang }


loadFloor : API.Config -> Bool -> String -> Task API.Error (Maybe Floor)
loadFloor apiConfig forEdit floorId =
  recover404 <|
    if forEdit then
      API.getEditingFloor apiConfig floorId
    else
      API.getFloor apiConfig floorId


recover404 : Task API.Error a -> Task API.Error (Maybe a)
recover404 task =
  task
    |> Task.map Just
    |> ( flip Task.onError) (\e ->
          case e of
            Http.BadResponse 404 _ ->
              Task.succeed Nothing

            e ->
              Task.fail e
       )