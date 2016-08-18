module Model.API exposing (
      getAuth
    , search
    , saveEditingFloor
    , publishEditingFloor
    , getEditingFloor
    , getFloor
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
    , getColors
    , getPrototypes
    , savePrototypes
    , Config
    , Error
  )

import String
import Http
import Task exposing (Task)

import Util.HttpUtil as HttpUtil exposing (..)
import Util.File exposing (File)

import Model.Floor as Floor
import Model.FloorDiff as FloorDiff exposing (..)
import Model.FloorInfo as FloorInfo exposing (FloorInfo)
import Model.User as User exposing (User)
import Model.Person exposing (Person)
import Model.Object as Object exposing (..)
import Model.Floor as Floor exposing (ImageSource(..))
import Model.Prototype exposing (Prototype)
import Model.Serialization exposing (..)
import Model.SearchResult exposing (SearchResult)
import Model.ColorPalette exposing (ColorPalette)

type alias Floor = Floor.Model

type alias Error = Http.Error

type alias Config =
  { apiRoot : String
  , accountServiceRoot : String
  , token : String
  }


-- createNewFloor : Task Error Int

saveEditingFloor : Config -> Floor -> ObjectsChange -> Task Error Int
saveEditingFloor config floor change =
  putJson
    decodeFloorVersion
    (config.apiRoot ++ "/v1/floors/" ++ floor.id)
    (authorization config.token)
    (Http.string <| serializeFloor floor change)


publishEditingFloor : Config -> String -> Task Error Int
publishEditingFloor config id =
  putJson
    decodeFloorVersion
    (config.apiRoot ++ "/v1/floors/" ++ id ++ "/public")
    (authorization config.token)
    (Http.string "")


getEditingFloor : Config -> String -> Task Error Floor
getEditingFloor config id =
  getFloorHelp config True id


getFloor : Config -> String -> Task Error Floor
getFloor config id =
  getFloorHelp config False id


getFloorHelp : Config -> Bool -> String -> Task Error Floor
getFloorHelp config withPrivate id =
  let
    _ =
      if id == "" then
        Debug.crash "id is not defined"
      else
        ""

    url =
      Http.url
        (config.apiRoot ++ "/v1/floors/" ++ id)
        (if withPrivate then [("all", "true")] else [])
  in
    getJsonWithoutCache decodeFloor url (authorization config.token)


getFloorMaybe : Config -> String -> Task Error (Maybe Floor)
getFloorMaybe config id =
  getFloor config id
  `Task.andThen` (\floor -> Task.succeed (Just floor))
  `Task.onError` \e -> case e of
    Http.BadResponse 404 _ -> Task.succeed Nothing
    _ -> Task.fail e


getFloorsInfo : Config -> Bool -> Task Error (List FloorInfo)
getFloorsInfo config withPrivate =
  let
    url =
      Http.url
        (config.apiRoot ++ "/v1/floors")
        (if withPrivate then [("all", "true")] else [])
  in
    getJsonWithoutCache
      decodeFloorInfoList
      url
      (authorization config.token)


getPrototypes : Config -> Task Error (List Prototype)
getPrototypes config =
  getJsonWithoutCache
    decodePrototypes
    (Http.url (config.apiRoot ++ "/v1/prototypes") [])
    (authorization config.token)


savePrototypes : Config -> List Prototype -> Task Error ()
savePrototypes config prototypes =
  putJsonNoResponse
    (config.apiRoot ++ "/v1/prototypes")
    (authorization config.token)
    (Http.string <| serializePrototypes prototypes)


getColors : Config -> Task Error ColorPalette
getColors config =
  getJsonWithoutCache
    decodeColors
    (Http.url (config.apiRoot ++ "/v1/colors") [])
    (authorization config.token)


getDiffSource : Config -> String -> Task Error (Floor, Maybe Floor)
getDiffSource config id =
  getEditingFloor config id
  `Task.andThen` \current -> getFloorMaybe config id
  `Task.andThen` \prev -> Task.succeed (current, prev)


getAuth : Config -> Task Error User
getAuth config =
  HttpUtil.get
    decodeUser
    (config.apiRoot ++ "/v1/self")
    (authorization config.token)


search : Config -> Bool -> String -> Task Error (List SearchResult)
search config withPrivate query =
  let
    url =
      Http.url
        (config.apiRoot ++ "/v1/search/" ++ Http.uriEncode query)
        (if withPrivate then [("all", "true")] else [])
  in
    HttpUtil.get
      decodeSearchResults
      url
      (authorization config.token)


personCandidate : Config -> String -> Task Error (List Person)
personCandidate config name =
  if String.isEmpty name then
    Task.succeed []
  else
    getJsonWithoutCache
      decodePersons
      (config.apiRoot ++ "/v1/candidates/" ++ Http.uriEncode name)
      (authorization config.token)


saveEditingImage : Config -> Id -> File -> Task a ()
saveEditingImage config id file =
  HttpUtil.sendFile
    "PUT"
    (config.apiRoot ++ "/v1/images/" ++ id)
    -- (authorization config.token)
    file


getPerson : Config -> Id -> Task Error Person
getPerson config id =
    HttpUtil.get
      decodePerson
      (config.apiRoot ++ "/v1/people/" ++ id)
      (authorization config.token)


getPersonByUser : Config -> Id -> Task Error Person
getPersonByUser config id =
  let
    getUser =
      HttpUtil.get
        decodeUser
        (config.apiRoot ++ "/v1/users/" ++ id)
        (authorization config.token)
  in
    getUser
    `Task.andThen` (\user -> case user of
        User.Admin person -> Task.succeed person
        User.General person -> Task.succeed person
        User.Guest -> Debug.crash ("user " ++ id ++ " has no person")
      )


login : String -> String -> String -> String -> Task Error String
login accountServiceRoot id tenantId pass =
  postJson
    decodeAuthToken
    (accountServiceRoot ++ "/v1/authentication")
    []
    (Http.string <| serializeLogin id tenantId pass)


goToLogin : Task a ()
goToLogin =
  HttpUtil.goTo "/login"


goToLogout : Task a ()
goToLogout =
  HttpUtil.goTo "/logout"


gotoTop : Task a ()
gotoTop =
  HttpUtil.goTo "/"
