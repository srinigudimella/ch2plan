module ViewGraph exposing (..)

import Dict as Dict exposing (Dict)
import Set as Set exposing (Set)
import Regex as Regex exposing (Regex)
import Html as H
import Html.Attributes as HA
import Svg as S
import Svg.Attributes as A
import Svg.Events as E
import Maybe.Extra
import Math.Vector2 as V2
import Draggable
import VirtualDom
import Json.Decode as Decode
import Model as M
import GameData as G
import Route


view : M.HomeModel -> Route.Features -> H.Html M.Msg
view model features =
    let
        selectable =
            M.selectableNodes M.startNodes model.char.graph model.selected
    in
        S.svg
            ([ HA.style [ ( "border", "1px solid grey" ) ]
             , A.viewBox <| formatViewBox (iconSize // 2) model.char.graph
             ]
                ++ Route.ifFeature features.zoom inputZoomAndPan []
            )
            [ S.g (Route.ifFeature features.zoom [ zoomAndPan model ] [])
                [ S.g [] (List.map (viewNodeBackground model.selected selectable model.search << Tuple.second) <| Dict.toList model.char.graph.nodes)
                , S.g [] (List.map (viewEdge << Tuple.second) <| Dict.toList model.char.graph.edges)
                , S.g [] (List.map (viewNode model.selected selectable model.search << Tuple.second) <| Dict.toList model.char.graph.nodes)
                ]
            ]


inputZoomAndPan : List (S.Attribute M.Msg)
inputZoomAndPan =
    [ handleZoom M.Zoom
    , Draggable.mouseTrigger () M.DragMsg
    ]


zoomAndPan : M.HomeModel -> S.Attribute msg
zoomAndPan model =
    let
        panning =
            "translate(" ++ toString (V2.getX model.center) ++ ", " ++ toString (V2.getY model.center) ++ ")"

        zooming =
            "scale(" ++ toString model.zoom ++ ")"
    in
        A.transform (zooming ++ " " ++ panning)


handleZoom : (Float -> msg) -> S.Attribute msg
handleZoom onZoom =
    let
        ignoreDefaults =
            VirtualDom.Options True True
    in
        VirtualDom.onWithOptions
            "wheel"
            ignoreDefaults
            (Decode.map onZoom <| Decode.field "deltaY" Decode.float)


formatViewBox : Int -> G.Graph -> String
formatViewBox margin g =
    [ G.graphMinX g - margin, G.graphMinY g - margin, G.graphWidth g + 2 * margin, G.graphHeight g + 2 * margin ]
        |> List.map toString
        |> String.join " "


viewEdge : G.Edge -> S.Svg msg
viewEdge ( a, b ) =
    S.line [ A.x1 <| toString a.x, A.y1 <| toString a.y, A.x2 <| toString b.x, A.y2 <| toString b.y, A.class "edge" ] []


appendTooltip =
    Maybe.Extra.unwrap "" ((++) "\n\n")


nodeQualityClass : G.NodeQuality -> String
nodeQualityClass =
    toString >> (++) "node-"


iconSize =
    50


nodeBGSize =
    iconSize * 4


iconUrl : G.NodeType -> String
iconUrl node =
    "./ch2data/img/" ++ node.icon ++ ".png"


viewNodeBackground : Set Int -> Set Int -> Maybe Regex -> G.Node -> S.Svg M.Msg
viewNodeBackground selected selectable q { id, x, y, val } =
    -- Backgrounds are drawn separately from the rest of the node, so they don't interfere with other nodes' clicks
    S.image
        [ A.class <| String.join " " [ "node-background", nodeHighlightClass q val, nodeSelectedClass selected id, nodeSelectableClass selectable id, nodeQualityClass val.quality ]
        , A.xlinkHref <| nodeBackgroundImage val (isNodeHighlighted q val) (Set.member id selected) (Set.member id selectable)
        , A.x <| toString <| x - nodeBGSize // 2
        , A.y <| toString <| y - nodeBGSize // 2
        , A.width <| toString nodeBGSize
        , A.height <| toString nodeBGSize
        ]
        []


viewNode : Set Int -> Set Int -> Maybe Regex -> G.Node -> S.Svg M.Msg
viewNode selected selectable q { id, x, y, val } =
    S.g
        [ A.class <| String.join " " [ "node", nodeHighlightClass q val, nodeSelectedClass selected id, nodeSelectableClass selectable id, nodeQualityClass val.quality ]
        ]
        [ S.title [] [ S.text <| nodeTooltipText val ]
        , S.image
            [ A.xlinkHref <| iconUrl val
            , A.x <| toString <| x - iconSize // 2
            , A.y <| toString <| y - iconSize // 2
            , A.width <| toString iconSize
            , A.height <| toString iconSize
            , E.onClick <| M.SelectInput id
            ]
            []
        ]


nodeBackgroundImage : G.NodeType -> Bool -> Bool -> Bool -> String
nodeBackgroundImage node isHighlighted isSelected isSelectable =
    let
        quality =
            case node.quality of
                G.Keystone ->
                    "deluxeNode"

                G.Notable ->
                    "specialNode"

                G.Plain ->
                    "generalNode"

        suffix =
            if isHighlighted then
                "Highlight"
            else if isSelected then
                -- SelectedVis has a green border, while Selected is just like in-game.
                -- Small nodes aren't visible enough when selected - too small,
                -- not enough color; in-game they're animated so it's more visible -
                -- so give them the border. Other nodes are visible enough without
                -- the extra border - much larger, with more color - so leave them alone.
                if node.quality == G.Plain then
                    "SelectedVis"
                else
                    "Selected"
            else if isSelectable then
                "Next"
            else
                ""
    in
        "./ch2data/node-img/" ++ quality ++ suffix ++ ".png?3"


nodeTooltipText : G.NodeType -> String
nodeTooltipText val =
    val.name ++ appendTooltip val.tooltip ++ appendTooltip val.flavorText


isNodeHighlighted : Maybe Regex -> G.NodeType -> Bool
isNodeHighlighted q0 t =
    Maybe.Extra.unwrap False (\q -> Regex.contains q <| nodeTooltipText t) q0


nodeHighlightClass : Maybe Regex -> G.NodeType -> String
nodeHighlightClass q t =
    if isNodeHighlighted q t then
        "node-highlight"
    else
        "node-nohighlight"


nodeSelectedClass : Set Int -> Int -> String
nodeSelectedClass selected id =
    if Set.member id selected then
        "node-selected"
    else
        "node-noselected"


nodeSelectableClass : Set Int -> Int -> String
nodeSelectableClass selected id =
    if Set.member id selected then
        "node-selectable"
    else
        "node-noselectable"
