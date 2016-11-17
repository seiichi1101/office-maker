module API.API exposing (
      getAuth
    , search
    , saveFloor
    , saveObjects
    , publishFloor
    , deleteEditingFloor
    , getEditingFloor
    , getFloor
    , getFloorOfVersion
    , getFloorsInfo
    , saveEditingImage
    , gotoTop
    , login
    , goToLogin
    , goToLogout
    , personCandidate
    , getDiffSource
    , getPerson
    , getPersonByUser
    , getPeopleByFloorAndPost
    , getColors
    , saveColors
    , getPrototypes
    , savePrototype
    , savePrototypes
    , Config
    , Error
  )

import Http
import Task exposing (Task)

import Util.HttpUtil as HttpUtil exposing (..)
import Util.File exposing (File)

import Model.Floor as Floor exposing (Floor, FloorBase)
import Model.FloorInfo as FloorInfo exposing (FloorInfo)
import Model.User as User exposing (User)
import Model.Person exposing (Person)
import Model.Object as Object exposing (..)
import Model.Floor as Floor exposing (Floor)
import Model.Prototype exposing (Prototype)
import Model.SearchResult exposing (SearchResult)
import Model.ColorPalette exposing (ColorPalette)
import Model.ObjectsChange as ObjectsChange exposing (ObjectsChange)
import API.Serialization exposing (..)


type alias Error = Http.Error


type alias Config =
  { apiRoot : String
  , accountServiceRoot : String
  , token : String
  }


saveObjects : Config -> ObjectsChange -> Task Error ObjectsChange
saveObjects config change =
  patchJson
    decodeObjectsChange
    (config.apiRoot ++ "/1/objects")
    [authorization config.token]
    (Http.jsonBody <| encodeObjectsChange change)


saveFloor : Config -> Floor -> Task Error FloorBase
saveFloor config floor =
  putJson
    decodeFloorBase
    (config.apiRoot ++ "/1/floors/" ++ floor.id)
    [authorization config.token]
    (Http.jsonBody <| encodeFloor floor)


publishFloor : Config -> String -> Task Error Floor
publishFloor config id =
  putJson
    decodeFloor
    (config.apiRoot ++ "/1/floors/" ++ id ++ "/public")
    [authorization config.token]
    Http.emptyBody


deleteEditingFloor : Config -> String -> Task Error ()
deleteEditingFloor config id =
  deleteJsonNoResponse
    (config.apiRoot ++ "/1/floors/" ++ id)
    [authorization config.token]
    Http.emptyBody


getEditingFloor : Config -> String -> Task Error Floor
getEditingFloor config id =
  getFloorHelp config True id


getFloor : Config -> String -> Task Error Floor
getFloor config id =
  getFloorHelp config False id


getFloorOfVersion : Config -> String -> Int -> Task Error Floor
getFloorOfVersion config id version =
  let
    url =
      makeUrl
        (config.apiRoot ++ "/1/floors/" ++ id ++ "/" ++ toString version)
        []
  in
    get decodeFloor url [authorization config.token]


getFloorHelp : Config -> Bool -> String -> Task Error Floor
getFloorHelp config withPrivate id =
  let
    url =
      makeUrl
        (config.apiRoot ++ "/1/floors/" ++ id)
        (if withPrivate then [("all", "true")] else [])
  in
    getWithoutCache decodeFloor url [authorization config.token]


getFloorMaybe : Config -> String -> Task Error (Maybe Floor)
getFloorMaybe config id =
  getFloor config id
    |> recover404


getFloorsInfo : Config -> Task Error (List FloorInfo)
getFloorsInfo config =
  getWithoutCache
    decodeFloorInfoList
    (makeUrl (config.apiRoot ++ "/1/floors") [])
    [authorization config.token]


getPrototypes : Config -> Task Error (List Prototype)
getPrototypes config =
  getWithoutCache
    decodePrototypes
    (makeUrl (config.apiRoot ++ "/1/prototypes") [])
    [authorization config.token]


savePrototypes : Config -> List Prototype -> Task Error ()
savePrototypes config prototypes =
  putJsonNoResponse
    (config.apiRoot ++ "/1/prototypes")
    [authorization config.token]
    (Http.jsonBody <| encodePrototypes prototypes)


savePrototype : Config -> Prototype -> Task Error ()
savePrototype config prototype =
  putJsonNoResponse
    (config.apiRoot ++ "/1/prototypes/" ++ prototype.id)
    [authorization config.token]
    (Http.jsonBody <| encodePrototype prototype)


getColors : Config -> Task Error ColorPalette
getColors config =
  getWithoutCache
    decodeColors
    (makeUrl (config.apiRoot ++ "/1/colors") [])
    [authorization config.token]


saveColors : Config -> ColorPalette -> Task Error ()
saveColors config colorPalette =
  putJsonNoResponse
    (config.apiRoot ++ "/1/colors")
    [authorization config.token]
    (Http.jsonBody <| encodeColorPalette colorPalette)


getDiffSource : Config -> String -> Task Error (Floor, Maybe Floor)
getDiffSource config id =
  getEditingFloor config id
    |> Task.andThen (\current -> getFloorMaybe config id
    |> Task.map (\prev -> (current, prev))
    )


getAuth : Config -> Task Error User
getAuth config =
  getWithoutCache
    decodeUser
    (config.apiRoot ++ "/1/self")
    [authorization config.token]


search : Config -> Bool -> String -> Task Error (List SearchResult)
search config withPrivate query =
  let
    url =
      makeUrl
        (config.apiRoot ++ "/1/search/" ++ Http.encodeUri query)
        (if withPrivate then [("all", "true")] else [])
  in
    HttpUtil.get
      decodeSearchResults
      url
      [authorization config.token]


personCandidate : Config -> String -> Task Error (List Person)
personCandidate config name =
  if String.isEmpty name then
    Task.succeed []
  else
    getWithoutCache
      decodePeople
      (config.apiRoot ++ "/1/people/search/" ++ Http.encodeUri name)
      [authorization config.token]


saveEditingImage : Config -> Id -> File -> Task a ()
saveEditingImage config id file =
  HttpUtil.sendFile
    "PUT"
    (config.apiRoot ++ "/1/images/" ++ id)
    [authorizationTuple config.token]
    file


getPerson : Config -> Id -> Task Error Person
getPerson config id =
  HttpUtil.get
    decodePerson
    (config.apiRoot ++ "/1/people/" ++ id)
    [authorization config.token]


getPersonByUser : Config -> Id -> Task Error Person
getPersonByUser config id =
  let
    getUser =
      HttpUtil.get
        decodeUser
        (config.apiRoot ++ "/1/users/" ++ id)
        [authorization config.token]
  in
    getUser
      |> Task.map (\user -> case user of
        User.Admin person -> person
        User.General person -> person
        User.Guest ->
          -- TODO how to deal with invalid person?
          { id = ""
          , name = ""
          , post = ""
          , mail = Nothing
          , tel = Nothing
          , image = Nothing
          }
      )


getPeopleByFloorAndPost : Config -> String -> Int -> String -> Task Error (List Person)
getPeopleByFloorAndPost config floorId floorVersion post =
  HttpUtil.get
    decodePeople
    ( makeUrl
        (config.apiRoot ++ "/1/people")
        [ ("floorId", floorId)
        , ("floorVersion", toString floorVersion)
        , ("post", post)
        ]
    )
    [authorization config.token]


login : String -> String -> String -> Task Error String
login accountServiceRoot id pass =
  postJson
    decodeAuthToken
    (accountServiceRoot ++ "/1/authentication")
    []
    (Http.jsonBody <| encodeLogin id pass)


goToLogin : Task a ()
goToLogin =
  HttpUtil.goTo "/login"


goToLogout : Task a ()
goToLogout =
  HttpUtil.goTo "/logout"


gotoTop : Task a ()
gotoTop =
  HttpUtil.goTo "/"
