module View.ContextMenu exposing (view)

import Html exposing (..)
import Html.Attributes exposing (..)

import View.Styles as S
import Util.HtmlUtil exposing (..)
import InlineHover exposing (hover)


view : List (msg, String, Maybe String) -> (Int, Int) -> (Int, Int) -> Html msg
view items windowSize (x, y) =
  div
    [ style (S.contextMenu (x, y + 37) windowSize (calculateHeight items)) -- TODO
    ]
    (List.map itemView items)


calculateHeight : List (msg, String, Maybe String) -> Int
calculateHeight items =
  items
    |> List.map (\(_, _, annotation) ->
      case annotation of
        Just _ ->
          S.contextMenuItemHeightWithAnnotation

        Nothing ->
          S.contextMenuItemHeight
      )
    |> List.sum


itemView : (msg, String, Maybe String) -> Html msg
itemView (msg, text_, annotation) =
  case annotation of
    Just ann ->
      hover S.contextMenuItemHover div
        [ style (S.contextMenuItem True)
        , onMouseDown' msg
        ]
        [ text text_
        , div [ style S.contextMenuItemAnnotation ] [ text ann ]
        ]

    Nothing ->
      hover S.contextMenuItemHover div
        [ style (S.contextMenuItem False)
        , onMouseDown' msg
        ]
        [ text text_ ]
