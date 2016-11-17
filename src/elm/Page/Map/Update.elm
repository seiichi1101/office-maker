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
import Model.Mode as Mode exposing (Mode(..), EditingMode(..), Tab(..))
import Model.User as User exposing (User)
import Model.Person as Person exposing (Person)
import Model.Object as Object exposing (..)
import Model.ObjectsOperation as ObjectsOperation
import Model.Scale as Scale
import Model.Prototype exposing (Prototype)
import Model.Prototypes as Prototypes exposing (Prototypes, PositionedPrototype)
import Model.Floor as Floor exposing (Floor)
import Model.FloorInfo as FloorInfo exposing (FloorInfo)
import Model.ObjectsChange as ObjectsChange exposing (ObjectsChange)
import Model.Errors as Errors exposing (GlobalError(..))
import Model.I18n as I18n exposing (Language(..))
import Model.SaveRequest as SaveRequest exposing (SaveRequest(..), ReducedSaveRequest)
import Model.EditingFloor as EditingFloor exposing (EditingFloor)
import Model.ClipboardData as ClipboardData
import Model.SearchResult as SearchResult

import API.API as API
import API.Cache as Cache exposing (Cache, UserState)

import Component.FloorProperty as FloorProperty
import Component.Header as Header
import Component.ObjectNameInput as ObjectNameInput

import Page.Map.Model as Model exposing (Model, ContextMenu(..), DraggingContext(..))
import Page.Map.Msg exposing (Msg(..))
import Page.Map.URL as URL exposing (URL)


type alias ObjectId = String
type alias PersonId = String


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
          Mode.isEditMode model.mode && not (User.isGuest user)

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

        mode =
          if not (User.isGuest user) then
            if needsEditMode then Editing EditTab Select else Viewing False
          else
            Viewing False
      in
        { model |
          user = user
        , scale = userState.scale
        , offset = userState.offset
        , lang = userState.lang
        , mode = mode
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
      { model
        | floorsInfo =
            floors
              |> List.map (\floor -> (FloorInfo.idOf floor, floor))
              |> Dict.fromList
      } ! []

    FloorLoaded floor ->
      updateOnFloorLoaded floor model

    ImageSaved url width height ->
      case model.floor of
        Nothing ->
          model ! []

        Just floor ->
          let
            (newFloor, rawFloor) =
              EditingFloor.updateFloor
                (Floor.setImage url width height)
                floor

            saveCmd =
              requestSaveFloorCmd rawFloor
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
          batchSave
            model.apiConfig
            (SaveRequest.reduceRequest (head :: tail))

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

    ObjectsSaved change ->
      { model |
        floor = Maybe.map (EditingFloor.syncObjects change) model.floor
      }  ! []

    FloorSaved floorBase ->
      { model
      | floorsInfo = FloorInfo.mergeFloor floorBase model.floorsInfo
      } ! []

    FloorPublished floor ->
      { model |
        floor = Maybe.map (\_ -> EditingFloor.init floor) model.floor
      , error = Success ("Successfully published " ++ floor.name)
      } !
        [ performAPI FloorsInfoLoaded (API.getFloorsInfo model.apiConfig)
        , Task.perform (always NoOp) Error <| (Process.sleep 3000.0 `andThen` \_ -> Task.succeed NoError)
        ]

    FloorDeleted floor ->
      { model |
        floor = Nothing
      , error = Success ("Successfully deleted " ++ floor.name)
      } !
        [ performAPI FloorsInfoLoaded (API.getFloorsInfo model.apiConfig)
        , Task.perform (always NoOp) Error <| (Process.sleep 3000.0 `andThen` \_ -> Task.succeed NoError)
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
            ShiftOffset ->
              NoDragging

            MoveFromSearchResult _ _ ->
              NoDragging

            MoveExistingObjectFromSearchResult _ _ _ _ ->
              NoDragging

            _ ->
              model.draggingContext
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
                  floor =
                    (Model.getEditingFloorOrDummy model)

                  objectsExcept target =
                    List.filter (\e -> idOf e /= idOf target) (Floor.objects floor)
                in
                  case (Floor.getObject lastTouchedId floor, Model.primarySelectedObject model) of
                    (Just object, Just primary) ->
                      List.map idOf <|
                        primary :: ObjectsOperation.withinRange (primary, object) (objectsExcept primary) --keep primary

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
          if Mode.isSelectMode model.mode then
            let
              (x, y) =
                ObjectsOperation.fitPositionToGrid model.gridSize <|
                  Model.screenToImageWithOffset model.scale (clientX, clientY) model.offset
            in
              Just (x, y, model.gridSize, model.gridSize)

          else
            model.selectorRect

        draggingContext =
          case model.mode of
            Editing _ Mode.Label ->
              NoDragging

            Editing _ Stamp ->
              StampFromScreenPos (clientX, clientY)

            Editing _ Pen ->
              PenFromScreenPos (clientX, clientY)

            Editing _ Select ->
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
          if Mode.isLabelMode model.mode then
            updateOnFinishLabel model
          else
            (model', Cmd.none)

        newModel =
          { model'' |
            pos = (clientX, clientY)
          -- , selectedObjects = []
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

    StartEditObject objectId ->
      model.floor
        |> (flip Maybe.andThen) (\efloor ->
          Floor.getObject objectId (EditingFloor.present efloor)
            |> Maybe.map (\object ->
              let
                newModel =
                  Model.startEdit object
                    { model |
                      selectedResult = Nothing
                    , contextMenu = NoContextMenu
                    }
              in
                newModel !
                  [ requestCandidate (idOf object) (nameOf object)
                  , focusCmd
                  ]
            )
        )
        |> Maybe.withDefault (model ! [])

    SelectBackgroundColor color ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            (newFloor, objectsChange) =
              EditingFloor.updateObjects
                (Floor.changeObjectBackgroundColor model.selectedObjects color)
                editingFloor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
            (newFloor, objectsChange) =
              EditingFloor.updateObjects
                (Floor.changeObjectColor model.selectedObjects color)
                editingFloor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
            (newFloor, objectsChange) =
              EditingFloor.updateObjects
                (Floor.changeObjectShape model.selectedObjects shape)
                editingFloor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
            (newFloor, objectsChange) =
              EditingFloor.updateObjects
                (Floor.changeObjectFontSize model.selectedObjects fontSize)
                editingFloor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
                  (newFloor, objectsChange) =
                    EditingFloor.updateObjects
                      (Floor.unsetPerson objectId)
                      editingFloor

                  saveCmd =
                    requestSaveObjectsCmd objectsChange
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

            (newFloor, objectsChange) =
              EditingFloor.updateObjects
                (Floor.setPeople matchedPairs)
                editingFloor

            saveCmd =
              requestSaveObjectsCmd objectsChange

            allPeople =
              List.concatMap snd pairs

            personInfo =
              DictUtil.addAll (.id) allPeople model.personInfo
          in
            { model |
              floor = Just newFloor
            , personInfo = personInfo
            } ! [ saveCmd ]

    ShowContextMenuOnObject objectId ->
      let
        selectedObjects =
          if List.member objectId model.selectedObjects then
            model.selectedObjects
          else
            [objectId]

        maybeLoadPersonCmd =
          model.floor `Maybe.andThen` \eFloor ->
          Floor.getObject objectId (EditingFloor.present eFloor) `Maybe.andThen` \obj ->
          Object.relatedPerson obj `Maybe.andThen` \personId ->
          Just (getAndCachePersonIfNotCached personId model)

        cmd =
          Maybe.withDefault Cmd.none maybeLoadPersonCmd
      in
        { model |
          contextMenu = Model.Object model.pos objectId
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

    GoToFloor maybeNextFloor ->
      let
        loadCmd =
          maybeNextFloor
            |> (flip Maybe.andThen)
              (\(floorId, requestLastEdit) ->
                let
                  load =
                    performAPI FloorLoaded (loadFloor model.apiConfig requestLastEdit floorId)
                in
                  case model.floor of
                    Just efloor ->
                      if (EditingFloor.present efloor).id == floorId then
                        Nothing
                      else
                        Just load

                    Nothing ->
                      Just load
              )
            |> Maybe.withDefault Cmd.none

        newModel =
          { model |
            contextMenu = NoContextMenu
          }
      in
        newModel !
          [ loadCmd
          , Navigation.modifyUrl (URL.serialize newModel)
          ]

    SelectSamePost postName ->
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
                    floor.version
                    postName
                )

            newModel =
              { model |
                contextMenu = NoContextMenu
              }
          in
            newModel ! [ cmd ]

    SearchByPost postName ->
      submitSearch
        { model
        | searchQuery = postName
        , mode = Mode.showSearchTab model.mode
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
          ) (Floor.objects <| Model.getEditingFloorOrDummy model)

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
              case Floor.getObject id floor of
                Just object ->
                  let
                    island =
                      ObjectsOperation.island
                        [object]
                        (List.filter (\e -> (Object.idOf e) /= id) (Floor.objects floor))
                  in
                    { model |
                      selectedObjects = List.map Object.idOf island
                    , contextMenu = NoContextMenu
                    }

                Nothing ->
                  model
          in
            newModel ! []

        Nothing ->
          model ! []

    SelectSameColor objectId ->
      model.floor
        |> Maybe.map EditingFloor.present
        |> (flip Maybe.andThen) (\floor ->
          Floor.getObject objectId floor
            |> Maybe.map (\object ->
              let
                backgroundColor =
                  Object.backgroundColorOf object

                target =
                  List.filter
                    (\e -> (backgroundColorOf e) == backgroundColor)
                    (Floor.objects floor)
              in
                { model |
                  selectedObjects = List.map Object.idOf target
                , contextMenu = NoContextMenu
                } ! []
            )
          )
        |> Maybe.withDefault (model ! [])

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

    ChangeMode editingMode ->
      { model | mode = Mode.changeEditingMode editingMode model.mode } ! []

    PrototypesMsg msg ->
      let
        newModel =
          { model |
            prototypes = Prototypes.update msg model.prototypes
          , mode = Mode.toStampMode model.mode -- TODO if event == select
          }
      in
        newModel ! []

    RegisterPrototype objectId ->
      let
        object =
          model.floor
            |> (flip Maybe.andThen) (\floor -> Floor.getObject objectId (EditingFloor.present floor))

        model' =
          { model |
            contextMenu = NoContextMenu
          }
      in
        case object of
          Just o ->
            let
              (_, _, width, height) = rect o

              (newId, seed) = IdGenerator.new model.seed

              newPrototypes =
                Prototypes.register
                  { id = newId
                  , color = colorOf o
                  , backgroundColor = backgroundColorOf o
                  , name = nameOf o
                  , width = width
                  , height = height
                  , fontSize = fontSizeOf o
                  , shape = shapeOf o
                  , personId = Nothing
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
            (newFloor, objectsChange) =
              EditingFloor.updateObjects
                (Floor.rotateObject id)
                editingFloor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
            (newFloor, objectsChange) =
              EditingFloor.updateObjects
                (Floor.toFirstNameOnly ids)
                editingFloor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
            (newFloor, objectsChange) =
              EditingFloor.updateObjects (Floor.removeSpaces ids) editingFloor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
            mode =
              Mode.toggleEditing model.mode
          }

        withPrivate =
          Mode.isEditMode newModel.mode && not (User.isGuest newModel.user)

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

    TogglePrintView ->
      { model |
        mode = Mode.togglePrintView model.mode
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
          results
            |> List.filterMap SearchResult.getPersonId
            |> List.map (regesterPersonIfNotCached model.apiConfig model.personInfo)
            |> Cmd.batch

        selectedResult =
          case results of
            SearchResult.Object object floorId :: [] ->
              Just (idOf object)

            _ ->
              Nothing

        searchResult =
          Just results
      in
        { model |
          searchResult = searchResult
        , selectedResult = selectedResult
        } ! [ regesterPersonCmd ]

    SelectSearchResult result ->
      let
        (newModel, cmd1) =
          case result of
            SearchResult.Object object floorId ->
              let
                model_ =
                  Model.adjustOffset
                    { model |
                      selectedResult = Just (idOf object)
                    }

                requestPrivateFloors =
                  Mode.isEditMode model_.mode && not (User.isGuest model_.user)

                goToFloor =
                  Task.perform
                    identity
                    GoToFloor
                    (Task.succeed (Just (floorId, requestPrivateFloors)))
              in
                model_ ! [ goToFloor ]

            _ ->
              (model, Cmd.none)

        regesterPersonCmd =
          SearchResult.getPersonId result
            |> Maybe.map (regesterPersonIfNotCached model.apiConfig model.personInfo)
            |> Maybe.withDefault Cmd.none
      in
        newModel ! [ cmd1, regesterPersonCmd ]

    StartDraggingFromMissingPerson personId personName ->
      let
        prototype =
          Prototypes.selectedPrototype model.prototypes
      in
        { model |
          contextMenu = NoContextMenu
        , draggingContext =
            MoveFromSearchResult
              { prototype
              | name = personName
              , personId = Just personId
              }
              personId
        } ! []

    StartDraggingFromExistingObject objectId name personId floorId updateAt ->
      let
        prototype =
          Prototypes.selectedPrototype model.prototypes
      in
        { model |
          contextMenu = NoContextMenu
        , draggingContext =
            MoveExistingObjectFromSearchResult
              floorId
              updateAt
              { prototype
              | name = name
              , personId = personId
              }
              objectId
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
                (newFloor, objectsChange) =
                  EditingFloor.updateObjects
                    (Floor.setPerson objectId head)
                    editingFloor

                saveCmd =
                  requestSaveObjectsCmd objectsChange
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
      { model | mode = Mode.changeTab tab model.mode } ! []

    ClosePopup ->
      { model | selectedResult = Nothing } ! []

    ShowDetailForObject objectId ->
      case model.floor of
        Nothing ->
          model ! []

        Just floor ->
          let
            maybePersonId =
              Floor.getObject objectId (EditingFloor.present floor)
                |> (flip Maybe.andThen) Object.relatedPerson

            cmd =
              case maybePersonId of
                Just personId -> regesterPerson model.apiConfig personId
                Nothing -> Cmd.none
          in
            ({ model |
              selectedResult = Just objectId
            } |> Model.adjustOffset
            ) ! [ cmd ]

    CreateNewFloor ->
      let
        (newFloorId, newSeed) =
          IdGenerator.new model.seed

        lastFloorOrder =
          model.floorsInfo
            |> FloorInfo.toEditingList
            |> List.reverse
            |> List.head
            |> Maybe.map .ord
            |> Maybe.withDefault 0

        newFloor =
          Floor.initWithOrder newFloorId lastFloorOrder

        cmd =
          performAPI
            FloorsInfoLoaded
            ( API.saveFloor model.apiConfig newFloor `andThen` \_ ->
              API.getFloorsInfo model.apiConfig
            )

        newModel =
          { model | seed = newSeed
          , floor = Just (EditingFloor.init newFloor)
          }
      in
        newModel !
          [ cmd
          , Navigation.modifyUrl (URL.serialize newModel)
          ]

    CopyFloor floorId withEmptyObjects ->
      case model.floor of
        Nothing ->
          model ! []

        Just editingFloor ->
          let
            floor =
              EditingFloor.present editingFloor

            (newFloorId, newSeed) =
              IdGenerator.new model.seed

            newFloor =
              Floor.copy withEmptyObjects newFloorId floor

            saveCmd =
              performAPI
                FloorsInfoLoaded
                ( API.saveFloor model.apiConfig newFloor `andThen` \_ ->
                  ( if withEmptyObjects then
                      API.saveObjects model.apiConfig (ObjectsChange.added (Floor.objects newFloor))
                    else
                      Task.succeed ObjectsChange.empty
                  ) `andThen` \_ ->
                  API.getFloorsInfo model.apiConfig
                )

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
      , mode = Viewing False
      } ! []

    Undo ->
      case model.floor of
        Nothing ->
          model ! []

        Just floor ->
          let
            (newFloor, objectsChange) =
              EditingFloor.undo floor

            saveCmd =
              requestSaveObjectsCmd objectsChange
          in
            { model | floor = Just newFloor } ! [ saveCmd ]

    Redo ->
      case model.floor of
        Nothing ->
          model ! []

        Just floor ->
          let
            (newFloor, objectsChange) =
              EditingFloor.redo floor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
              ClipboardData.toObjectCandidates prototype (left, top) s

            ((newModel, cmd), newObjects) =
              updateOnFinishStamp_ candidates model floor

            task =
              List.foldl
                (\object prevTask ->
                  prevTask `andThen` \list ->
                    Task.map (\people ->
                      (Object.idOf object, people) :: list
                    ) (API.personCandidate model.apiConfig (Object.nameOf object)) -- TODO too many requests
                ) (Task.succeed []) newObjects

            autoMatchingCmd =
              performAPI GotMatchingList task
          in
            { newModel |
              selectedObjects = List.map (Object.idOf) newObjects
            } ! [ cmd, autoMatchingCmd ]

        _ ->
          model ! []

    SyncFloor ->
      case model.floor of
        Just editingFloor ->
          let
            requestPrivateFloors =
              Mode.isEditMode model.mode && not (User.isGuest model.user)

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

        MoveFromSearchResult prototype personId ->
          updateOnFinishStamp model

        MoveExistingObjectFromSearchResult oldFloorId updateAt _ objectId ->
          case model.floor of
            Just editingFloor ->
              let
                (newSeed, newFloor, newObjects_, _) =
                  updateOnFinishStampWithoutEffects
                    (Just objectId)
                    (Model.getPositionedPrototype model)
                    model
                    editingFloor

                -- currently, only one desk is made
                newObjects =
                  List.map (Object.setUpdateAt updateAt) newObjects_

                objectsChange =
                  ObjectsChange.modified
                    (List.map (\object -> (Object.idOf object, object)) newObjects)

                saveCmd =
                  requestSaveObjectsCmd objectsChange

                searchResult =
                  model.searchResult
                    |> Maybe.map (SearchResult.mergeObjectInfo (EditingFloor.present newFloor).id (Floor.objects <| EditingFloor.present newFloor))
                    |> Maybe.map (SearchResult.moveObject oldFloorId newObjects)

                registerPersonCmd =
                  newObjects
                    |> List.filterMap Object.relatedPerson
                    |> List.head
                    |> Maybe.map (\personId -> getAndCachePersonIfNotCached personId model)
                    |> Maybe.withDefault Cmd.none
              in
                { model
                  | seed = newSeed
                  , floor = Just newFloor
                  , searchResult = searchResult
                } ! [ saveCmd, registerPersonCmd ]

            _ ->
              model ! []

        _ ->
          model ! []

    newModel =
      { model' |
        draggingContext = NoDragging
      }
  in
    newModel ! [ cmd ]


updateOnSelectCandidate : ObjectId -> PersonId -> Model -> (Model, Cmd Msg)
updateOnSelectCandidate objectId personId model =
  case (model.floor, Dict.get personId model.personInfo) of
    (Just floor, Just person) ->
      let
        (newFloor, objectsChange) =
          EditingFloor.updateObjects
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
      fst <| updateOnFinishStamp_ (Model.getPositionedPrototype model) model floor

    Nothing ->
      model ! []


updateOnFinishStamp_ : List PositionedPrototype -> Model -> EditingFloor -> ((Model, Cmd Msg), List Object)
updateOnFinishStamp_ prototypes model floor =
  let
    (newSeed, newFloor, newObjects, objectsChange) =
      updateOnFinishStampWithoutEffects Nothing prototypes model floor

    searchResult =
      model.searchResult
        |> Maybe.map (SearchResult.mergeObjectInfo (EditingFloor.present newFloor).id (Floor.objects <| EditingFloor.present newFloor))

    saveCmd =
      requestSaveObjectsCmd objectsChange
  in
    ( ( { model
          | seed = newSeed
          , floor = Just newFloor
          , searchResult = searchResult
          , mode = Mode.toSelectMode model.mode
        }
        , saveCmd
      )
    , newObjects
    )

-- TODO Need a hard refactor around here

updateOnFinishStampWithoutEffects : Maybe String -> List PositionedPrototype -> Model -> EditingFloor -> (Seed, EditingFloor, List Object, ObjectsChange)
updateOnFinishStampWithoutEffects maybeObjectId prototypes model floor =
  let
    (candidatesWithNewIds, newSeed) =
      IdGenerator.zipWithNewIds model.seed prototypes

    newObjects =
      List.map
        (\((prototype, (x, y)), newId) ->
            Object.initDesk
              (Maybe.withDefault newId maybeObjectId)
              (EditingFloor.present floor).id
              Nothing
              (x, y, prototype.width, prototype.height)
              prototype.backgroundColor
              prototype.name
              prototype.fontSize
              Nothing
              prototype.personId
        )
        candidatesWithNewIds

    (newFloor, objectsChange) =
      EditingFloor.updateObjects (Floor.addObjects newObjects) floor
  in
    (newSeed, newFloor, newObjects, objectsChange)


updateOnFinishPen : (Int, Int) -> Model -> (Model, Cmd Msg)
updateOnFinishPen (x, y) model =
  case (model.floor, Model.temporaryPen model (x, y)) of
    (Just floor, Just (color, name, (left, top, width, height))) ->
      let
        (newId, newSeed) =
          IdGenerator.new model.seed

        newObject =
          Object.initDesk
            newId
            (EditingFloor.present floor).id
            Nothing
            (left, top, width, height)
            color
            name
            Object.defaultFontSize
            Nothing
            Nothing

        (newFloor, objectsChange) =
          EditingFloor.updateObjects
            (Floor.addObjects [ newObject ])
            floor

        saveCmd =
          requestSaveObjectsCmd objectsChange
      in
        { model |
          seed = newSeed
        , floor = Just newFloor
        } ! [ saveCmd ]

    _ ->
      model ! []


updateOnFinishResize : ObjectId -> (Int, Int) -> Model -> (Model, Cmd Msg)
updateOnFinishResize objectId (x, y) model =
  model.floor
    |> (flip Maybe.andThen) (\editingFloor -> Floor.getObject objectId (EditingFloor.present editingFloor)
    |> (flip Maybe.andThen) (\e -> Model.temporaryResizeRect model (x, y) (rect e)
    |> Maybe.map (\(_, _, width, height) ->
        let
          (newFloor, objectsChange) =
            EditingFloor.updateObjects (Floor.resizeObject objectId (width, height)) editingFloor

          saveCmd =
            requestSaveObjectsCmd objectsChange
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
          ObjectsOperation.fitPositionToGrid model.gridSize <|
            Model.screenToImageWithOffset model.scale model.pos model.offset

        (width, height) =
          ObjectsOperation.fitSizeToGrid model.gridSize (100, 100) -- TODO configure?

        bgColor = "transparent" -- TODO configure?

        color = "#000"

        name = ""

        fontSize = 40 -- TODO

        (newId, newSeed) =
          IdGenerator.new model.seed

        newObject =
          Object.initLabel
            newId
            (EditingFloor.present newFloor).id
            Nothing
            (left, top, width, height)
            bgColor
            name
            fontSize
            Nothing
            color
            Object.Rectangle

        (newFloor, objectsChange) =
          EditingFloor.updateObjects
            (Floor.addObjects [ newObject ])
            floor

        saveCmd =
          requestSaveObjectsCmd objectsChange

        model' =
          { model |
            seed = newSeed
          , mode = Mode.toSelectMode model.mode
          , floor = Just newFloor
          }
      in
        case Floor.getObject newId (EditingFloor.present newFloor) of
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
              floorsInfo = FloorInfo.mergeFloor (Floor.baseOf floor) model.floorsInfo
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


getAndCachePersonIfNotCached : PersonId -> Model -> Cmd Msg
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
        (newFloor, rawFloor) =
          EditingFloor.updateFloor (Floor.changeName name) efloor

        saveCmd =
          requestSaveFloorCmd rawFloor
      in
        (newFloor, seed) ! [ saveCmd ]

    FloorProperty.OnOrdChange ord ->
      let
        (newFloor, rawFloor) =
          EditingFloor.updateFloor (Floor.changeOrd ord) efloor

        saveCmd =
          requestSaveFloorCmd rawFloor
      in
        (newFloor, seed) ! [ saveCmd ]

    FloorProperty.OnRealSizeChange (w, h) ->
      let
        (newFloor, rawFloor) =
          EditingFloor.updateFloor (Floor.changeRealSize (w, h)) efloor

        saveCmd =
          requestSaveFloorCmd rawFloor
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


regesterPerson : API.Config -> PersonId -> Cmd Msg
regesterPerson apiConfig personId =
  performAPI identity <|
    API.getPerson apiConfig personId `andThen` \person ->
      Task.succeed (RegisterPeople [person])


regesterPersonIfNotCached : API.Config -> Dict PersonId Person -> PersonId -> Cmd Msg
regesterPersonIfNotCached apiConfig personInfo personId =
  if Dict.member personId personInfo then
    Cmd.none
  else
    regesterPerson apiConfig personId


updateOnFinishNameInput : Bool -> ObjectId -> String -> Model -> (Model, Cmd Msg)
updateOnFinishNameInput continueEditing objectId name model =
  case model.floor of
    Nothing ->
      model ! []

    Just efloor ->
      let
        floor =
          EditingFloor.present efloor

        (objectNameInput, requestCandidateCmd) =
          case Floor.getObject objectId floor of
            Just object ->
              if continueEditing then
                case nextObjectToInput object (Floor.objects floor) of
                  Just e ->
                    ( ObjectNameInput.start (idOf e, nameOf e) model.objectNameInput
                    , requestCandidate (idOf e) (nameOf e)
                    )

                  Nothing ->
                    ( model.objectNameInput
                    , requestCandidate objectId name
                    )
              else
                (model.objectNameInput, Cmd.none)

            Nothing ->
              (model.objectNameInput, Cmd.none)

        registerPersonDetailCmd =
          case Floor.getObject objectId floor of
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

        (newFloor, objectsChange) =
          EditingFloor.updateObjects
            (Floor.changeObjectName [objectId] name)
            efloor

        saveCmd =
          requestSaveObjectsCmd objectsChange

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
    island =
      ObjectsOperation.island
        [object]
        (List.filter (\e -> (idOf e) /= (idOf object)) allObjects)
  in
    case ObjectsOperation.nearest Down object island of
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


requestSaveObjectsCmd : ObjectsChange -> Cmd Msg
requestSaveObjectsCmd objectsChange =
  requestCmd (SaveObjects objectsChange)


requestSaveFloorCmd : Floor -> Cmd Msg
requestSaveFloorCmd floor =
  requestCmd (SaveFloor floor)


requestPublishFloorCmd : String -> Cmd Msg
requestPublishFloorCmd id =
  requestCmd (PublishFloor id)


requestCmd : SaveRequest -> Cmd Msg
requestCmd req =
  Task.perform identity RequestSave (Task.succeed req)


batchSave : API.Config -> ReducedSaveRequest -> Cmd Msg
batchSave apiConfig request =
  let
    publishFloorCmd =
      request.publish
        |> Maybe.map (API.publishFloor apiConfig)
        |> Maybe.map (performAPI FloorPublished)
        |> Maybe.withDefault Cmd.none

    saveFloorCmd =
      request.floor
        |> Maybe.map (API.saveFloor apiConfig)
        |> Maybe.map (performAPI FloorSaved)
        |> Maybe.withDefault Cmd.none

    saveObjectsCmd =
      API.saveObjects apiConfig request.objects
        |> (performAPI ObjectsSaved)
  in
    Cmd.batch [ publishFloorCmd, saveFloorCmd, saveObjectsCmd ]


updateByKeyEvent : ShortCut.Event -> Model -> (Model, Cmd Msg)
updateByKeyEvent event model =
  -- Patterns are separated because of the worst-case performance of pattern match.
  -- https://github.com/elm-lang/elm-compiler/issues/1362
  if model.keys.ctrl then
    updateByKeyEventWithCtrl event model
  else if model.keys.shift then
    updateByKeyEventWithShift event model
  else
    updateByKeyEventWithNoControlKeys event model


updateByKeyEventWithCtrl : ShortCut.Event -> Model -> (Model, Cmd Msg)
updateByKeyEventWithCtrl event model =
  case (model.floor, event) of
    (Just floor, ShortCut.A) ->
      { model |
        selectedObjects =
          List.map idOf <| Floor.objects (EditingFloor.present floor)
      } ! []

    (Just floor, ShortCut.C) ->
      { model |
        copiedObjects = Model.selectedObjects model
      } ! []

    (Just floor, ShortCut.V) ->
      case model.selectorRect of
        Just (x, y, w, h) ->
          let
            base = (x, y)

            (copiedIdsWithNewIds, newSeed) =
              IdGenerator.zipWithNewIds model.seed model.copiedObjects

            (newFloor, objectsChange) =
              EditingFloor.updateObjects (Floor.paste copiedIdsWithNewIds base) floor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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

        Nothing ->
          model ! []

    (Just floor, ShortCut.X) ->
      let
        (newFloor, objectsChange) =
          EditingFloor.updateObjects (Floor.removeObjects model.selectedObjects) floor

        saveCmd =
          requestSaveObjectsCmd objectsChange
      in
        { model |
          floor = Just newFloor
        , copiedObjects = Model.selectedObjects model
        , selectedObjects = []
        } ! [ saveCmd ]

    _ ->
      model ! []


updateByKeyEventWithShift : ShortCut.Event -> Model -> (Model, Cmd Msg)
updateByKeyEventWithShift event model =
  case (model.floor, event) of
    (Just floor, ShortCut.UpArrow) ->
      Model.expandOrShrinkToward Up model ! []

    (Just floor, ShortCut.DownArrow) ->
      Model.expandOrShrinkToward Down model ! []

    (Just floor, ShortCut.LeftArrow) ->
      Model.expandOrShrinkToward Left model ! []

    (Just floor, ShortCut.RightArrow) ->
      Model.expandOrShrinkToward Right model ! []

    _ ->
      model ! []


updateByKeyEventWithNoControlKeys : ShortCut.Event -> Model -> (Model, Cmd Msg)
updateByKeyEventWithNoControlKeys event model =
  case (model.floor, event) of
    (Just floor, ShortCut.UpArrow) ->
      moveSelecedObjectsToward Up model floor

    (Just floor, ShortCut.DownArrow) ->
      moveSelecedObjectsToward Down model floor

    (Just floor, ShortCut.LeftArrow) ->
      moveSelecedObjectsToward Left model floor

    (Just floor, ShortCut.RightArrow) ->
      moveSelecedObjectsToward Right model floor

    (Just floor, ShortCut.Del) ->
      let
        (newFloor, objectsChange) =
          EditingFloor.updateObjects (Floor.removeObjects model.selectedObjects) floor

        saveCmd =
          requestSaveObjectsCmd objectsChange
      in
        { model |
          floor = Just newFloor
        } ! [ saveCmd ]

    (Just floor, ShortCut.Other 9) ->
      Model.shiftSelectionToward Right model ! []

    _ ->
      model ! []


moveSelecedObjectsToward : Direction -> Model -> EditingFloor -> (Model, Cmd Msg)
moveSelecedObjectsToward direction model editingFloor =
  let
    shift =
      Direction.shiftTowards direction model.gridSize

    (newFloor, objectsChange) =
      EditingFloor.updateObjects
        (Floor.move model.selectedObjects model.gridSize shift)
        editingFloor

    saveCmd =
      requestSaveObjectsCmd objectsChange
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
            (newFloor, objectsChange) =
              EditingFloor.updateObjects
                (Floor.move model.selectedObjects model.gridSize shift)
                floor

            saveCmd =
              requestSaveObjectsCmd objectsChange
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
