module Model exposing
    ( Error(..)
    , Flags
    , Model
    , Msg(..)
    , StatsSummary
    , center
    , init
    , nodeIconSize
    , nodeSummary
    , parseStatsSummary
    , statsSummary
    , subscriptions
    , update
    , visibleTooltip
    , zoom
    )

import Browser
import Browser.Events
import Browser.Navigation as Nav
import Dict as Dict exposing (Dict)
import Dict.Extra
import Draggable
import GameData as G
import GameData.Stats as GS
import Json.Decode as Decode
import Lazy as Lazy exposing (Lazy)
import List.Extra
import Math.Vector2 as V2
import Maybe.Extra
import Model.Dijkstra as Dijkstra
import Model.Graph as Graph exposing (GraphModel)
import Ports
import Process
import Regex as Regex exposing (Regex)
import Route as Route exposing (Features, Route)
import Set as Set exposing (Set)
import Task
import Time
import Url as Url exposing (Url)


type Msg
    = SearchInput String
    | SearchNav (Maybe String) (Maybe String)
    | SearchHelp Bool
    | NodeMouseDown G.NodeId
    | NodeMouseUp G.NodeId
    | NodeMouseOver G.NodeId
    | NodeMouseOut G.NodeId
    | NodeLongPress G.NodeId
    | NavRequest Browser.UrlRequest
    | NavLocation Url
    | Preprocess
    | OnDragBy V2.Vec2
    | DragMsg (Draggable.Msg ())
    | Zoom Float
    | Resize WindowSize
    | ToggleSidebar
    | SaveFileSelected String
    | SaveFileImport Ports.SaveFileData


type alias Model =
    { urlKey : Nav.Key
    , changelog : String
    , gameData : G.GameData
    , route : Route
    , graph : Maybe Graph.GraphModel
    , features : Features
    , windowSize : WindowSize
    , tooltip : Maybe ( G.NodeId, TooltipState )
    , sidebarOpen : Bool
    , searchString : Maybe String
    , searchPrev : Maybe String
    , searchRegex : Maybe Regex
    , searchHelp : Bool
    , zoom : Float
    , center : V2.Vec2
    , drag : Draggable.State ()
    , error : Maybe Error
    }


type alias WindowSize =
    { width : Int, height : Int }


type Error
    = SearchRegexError
    | SaveImportError String
    | BuildNodesError String
    | GraphError String


type TooltipState
    = Hovering
    | Shortpressing
    | Longpressing


type alias Flags =
    { gameData : Decode.Value
    , changelog : String
    , windowSize : WindowSize
    }


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags loc urlKey =
    case Decode.decodeValue G.decoder flags.gameData of
        Ok gameData ->
            let
                route =
                    Route.parse loc

                search =
                    Route.params route |> Maybe.Extra.unwrap Nothing .search

                ( graph, error ) =
                    parseGraph gameData route
            in
            ( { urlKey = urlKey
              , changelog = flags.changelog
              , windowSize = flags.windowSize
              , gameData = gameData
              , features = Route.parseFeatures loc
              , route = route
              , graph = graph
              , sidebarOpen = True
              , tooltip = Nothing
              , searchString = search
              , searchPrev = search
              , searchRegex = Just Regex.never
              , searchHelp = False
              , zoom =
                    graph
                        |> Maybe.Extra.unwrap 1
                            (\{ char, selected } ->
                                clampZoom flags.windowSize char.graph <|
                                    if selected == Set.empty then
                                        1

                                    else
                                        0
                            )
              , center = V2.vec2 0 0
              , drag = Draggable.init
              , error = error
              }
            , Cmd.batch
                [ preprocessCmd
                , redirectCmd urlKey gameData route
                ]
            )

        Err err ->
            Debug.todo (Debug.toString err)


parseGraph : G.GameData -> Route -> ( Maybe GraphModel, Maybe Error )
parseGraph gameData route =
    let
        graphResult =
            Route.params route
                |> Result.fromMaybe "cannot graph this url"
                |> Result.andThen (Graph.parse gameData)
    in
    case graphResult of
        Err err ->
            ( Nothing, Just <| GraphError err )

        Ok ( g, Just err ) ->
            ( Just g, Just <| BuildNodesError err )

        Ok ( g, Nothing ) ->
            ( Just g, Nothing )


preprocessCmd : Cmd Msg
preprocessCmd =
    -- setTimeout to let the UI render, then run delayed calculations
    Process.sleep 1
        |> Task.andThen (always <| Task.succeed Preprocess)
        |> Task.perform identity


invert : comparable -> Set comparable -> Set comparable
invert id set =
    if Set.member id set then
        Set.remove id set

    else
        Set.insert id set


visibleTooltip : Model -> Maybe G.NodeId
visibleTooltip { tooltip } =
    case tooltip of
        Just ( id, Hovering ) ->
            Just id

        Just ( id, Longpressing ) ->
            Just id

        _ ->
            Nothing


updateNode : G.NodeId -> Model -> ( Model, Cmd Msg )
updateNode id model =
    let
        graph =
            case model.graph of
                Nothing ->
                    Debug.todo "can't updateNode without model.graph"

                Just graph_ ->
                    graph_

        params =
            case Route.params model.route of
                Nothing ->
                    Debug.todo "can't updateNode without route params"

                Just params_ ->
                    params_

        selected =
            if Set.member id graph.selected then
                -- remove the node, and any disconnected from the start by its removal
                graph.selected
                    |> invert id
                    |> Graph.reachableSelectedNodes graph.char.graph

            else
                -- add the node and any in between
                Dijkstra.selectPathToNode (Lazy.force graph.dijkstra) id
                    |> Set.fromList
                    |> Set.union graph.selected

        route =
            Route.Home
                { params | build = Graph.nodesToBuild graph.char.graph selected }
    in
    ( { model | error = Nothing }, Nav.pushUrl model.urlKey <| Route.stringify route )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SearchHelp open ->
            ( { model | searchHelp = open }, Cmd.none )

        SearchInput search0 ->
            -- Typing out a search in the search box. Do nothing while
            -- they type; when they stop typing, perform the search.
            let
                search =
                    if search0 == "" then
                        Nothing

                    else
                        Just search0
            in
            -- don't update searchRegex: wait, for performance.
            -- (Safety's not an issue anymore; Elm 0.19 fixed #44's crashes)
            -- https://github.com/erosson/ch2plan/issues/31
            -- https://github.com/erosson/ch2plan/issues/36
            -- https://github.com/erosson/ch2plan/issues/44
            ( { model | searchPrev = model.searchString, searchString = search }
            , Process.sleep 300 |> Task.perform (always <| SearchNav model.searchString search)
            )

        SearchNav from to ->
            if model.searchPrev == from then
                case model.route of
                    Route.Home params ->
                        let
                            searchRegex =
                                to
                                    |> Maybe.andThen
                                        (Debug.log "search"
                                            >> Regex.fromStringWith { caseInsensitive = True, multiline = True }
                                        )

                            error =
                                case ( to, searchRegex ) of
                                    ( Nothing, _ ) ->
                                        Nothing

                                    ( Just _, Just _ ) ->
                                        Nothing

                                    ( Just _, Nothing ) ->
                                        Just SearchRegexError
                        in
                        ( { model | graph = model.graph |> Maybe.map (\g -> { g | search = searchRegex }), error = error }
                        , { params | search = to } |> Route.Home |> Route.stringify |> Nav.replaceUrl model.urlKey
                        )

                    _ ->
                        -- can't search from pages without a searchbox
                        ( model, Cmd.none )

            else
                -- they typed something since the delay, do not update the url
                ( model, Cmd.none )

        NodeMouseOver id ->
            ( { model | tooltip = Just ( id, Hovering ) }, Cmd.none )

        NodeMouseOut id ->
            ( { model | tooltip = Nothing }, Cmd.none )

        NodeMouseDown id ->
            case model.tooltip of
                Nothing ->
                    -- clicked without hovering - this could be mobile/longpress.
                    -- (could also be a keyboard, but you want to tab through 700 nodes? sorry, not supported)
                    ( { model | tooltip = Just ( id, Shortpressing ) }
                    , Process.sleep 500 |> Task.perform (always <| NodeLongPress id)
                    )

                Just ( tid, state ) ->
                    if id /= tid then
                        -- multitouch...? I only support one tooltip at a time
                        ( { model | tooltip = Just ( id, Shortpressing ) }
                        , Process.sleep 500 |> Task.perform (always <| NodeLongPress id)
                        )

                    else
                        case state of
                            Hovering ->
                                -- Mouse-user, clicked while hovering. Select this node, don't wait for mouseout
                                updateNode id model

                            _ ->
                                -- Multitouch...? Ignore other mousedowns.
                                ( model, Cmd.none )

        NodeLongPress id ->
            case model.tooltip of
                -- waiting for the same longpress that sent this message?
                Just ( tid, Shortpressing ) ->
                    ( { model | tooltip = Just ( id, Longpressing ) }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        NodeMouseUp id ->
            case model.tooltip of
                Nothing ->
                    -- no idea how we got here, select the node I guess
                    updateNode id model

                Just ( tid, state ) ->
                    if id /= tid then
                        -- no idea how we got here, select the node I guess
                        updateNode id model

                    else
                        case state of
                            Hovering ->
                                -- mouse-user, clicked while hovering. Do nothing, mousedown already selected the node
                                ( model, Cmd.none )

                            Shortpressing ->
                                -- end of a quick tap - select the node and cancel the longpress
                                updateNode id { model | tooltip = Nothing }

                            Longpressing ->
                                -- end of a tooltip longpress - hide the tooltip
                                ( { model | tooltip = Nothing }, Cmd.none )

        Preprocess ->
            -- calculate dijkstra immediately after the view renders, so we have it ready later, when the user clicks.
            -- It's not *that* slow - 200ms-ish - but that's slow enough to make a difference.
            -- This makes things feel much more responsive.
            ( { model | graph = model.graph |> Maybe.map (\g -> { g | dijkstra = Lazy.evaluate g.dijkstra }) }, Cmd.none )

        OnDragBy rawDelta ->
            let
                delta =
                    rawDelta |> V2.scale (-1 / model.zoom)
            in
            ( { model | center = model.center |> V2.add delta }, Cmd.none )

        Zoom factor ->
            let
                newZoom =
                    model.graph
                        |> Maybe.map
                            (\{ char } ->
                                model.zoom
                                    |> (+) (-factor * 0.01)
                                    |> clampZoom model.windowSize char.graph
                            )
                        |> Maybe.withDefault model.zoom
            in
            ( { model | zoom = newZoom }, Cmd.none )

        DragMsg dragMsg ->
            Draggable.update dragConfig dragMsg model

        ToggleSidebar ->
            ( { model | sidebarOpen = not model.sidebarOpen }, Cmd.none )

        SaveFileSelected elemId ->
            ( model, Ports.saveFileSelected elemId )

        SaveFileImport data ->
            let
                _ =
                    Debug.log "SaveFileImport" data

                game =
                    model.graph |> Maybe.map .game |> Maybe.withDefault (G.latestVersion model.gameData)

                saveHero =
                    case data.error of
                        Nothing ->
                            Dict.Extra.find (\k v -> v.name == data.hero) game.heroes

                        _ ->
                            Nothing

                saveBuild =
                    String.join "&" data.build

                cmd =
                    case saveHero of
                        Just hero ->
                            Route.Home
                                { version = game.versionSlug
                                , search = model.searchString
                                , hero = Tuple.first hero
                                , build = Just saveBuild
                                }
                                |> Route.stringify
                                |> Nav.pushUrl model.urlKey

                        _ ->
                            Cmd.none
            in
            -- show errors, and/or redirect to the imported build
            ( { model | error = data.error |> Maybe.map SaveImportError }, cmd )

        NavRequest req ->
            -- https://package.elm-lang.org/packages/elm/browser/latest/Browser#UrlRequest
            case req of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.urlKey (Url.toString url) )

                Browser.External url ->
                    ( model, Nav.load url )

        NavLocation loc ->
            let
                route =
                    Route.parse loc

                ( graph, error ) =
                    parseGraph model.gameData route
            in
            ( { model
                | route = route
                , features = Route.parseFeatures loc
                , error = error
                , graph =
                    case ( graph, model.graph ) of
                        ( Just new, Just old ) ->
                            Just <| Graph.updateOnChange new old

                        ( Just new, Nothing ) ->
                            Just new

                        _ ->
                            Nothing
              }
            , Cmd.batch [ preprocessCmd, redirectCmd model.urlKey model.gameData route ]
            )

        Resize windowSize ->
            ( { model | windowSize = windowSize }, Cmd.none )


nodeIconSize =
    50


zoomedGraphSize : Model -> WindowSize -> { width : Float, height : Float }
zoomedGraphSize model window =
    { height = toFloat window.height / model.zoom
    , width = toFloat window.width / model.zoom
    }


clampZoom : WindowSize -> G.Graph -> Float -> Float
clampZoom window graph =
    -- Small windows can zoom out farther, so they can fit the entire graph on screen
    let
        minZoom =
            min
                (toFloat window.width / toFloat (G.graphWidth graph + nodeIconSize * 4))
                (toFloat window.height / toFloat (G.graphHeight graph + nodeIconSize * 4))
                |> min 0.5
    in
    clamp minZoom 3


redirect : G.GameData -> Route -> Maybe Route
redirect gameData route =
    case route of
        Route.Root params ->
            Just <| Route.Home <| Route.fromLegacyParams (G.latestVersionId gameData) params

        Route.LegacyHome params ->
            -- legacy urls are assigned a legacy version
            Just <| Route.Home <| Route.fromLegacyParams "0.052-beta" params

        _ ->
            Nothing


redirectCmd : Nav.Key -> G.GameData -> Route -> Cmd Msg
redirectCmd urlKey gameData route =
    redirect gameData route
        |> Maybe.Extra.unwrap Cmd.none (Route.stringify >> Nav.replaceUrl urlKey)


zoom : Model -> GraphModel -> Float
zoom model { char } =
    clampZoom model.windowSize char.graph model.zoom


center : Model -> GraphModel -> V2.Vec2
center model home =
    clampCenter model home model.center


clampCenter : Model -> GraphModel -> V2.Vec2 -> V2.Vec2
clampCenter model { char } =
    let
        ( minXY, maxXY ) =
            centerBounds (model.windowSize |> zoomedGraphSize model) char.graph
    in
    -- >> Debug.log "clampCenter"
    v2Clamp minXY maxXY


centerBounds w g =
    -- when panning, for any zoom level, we should stop scrolling around the
    -- edge of the graph, where empty space begins. That means the center is
    -- clamped to a smaller area as zoom gets more distant.
    ( V2.vec2
        ((G.graphMinX g |> toFloat) + w.width / 2 - nodeIconSize |> min 0)
        ((G.graphMinY g |> toFloat) + w.height / 2 - nodeIconSize |> min 0)
    , V2.vec2
        ((G.graphMaxX g |> toFloat) - w.width / 2 + nodeIconSize |> max 0)
        ((G.graphMaxY g |> toFloat) - w.height / 2 + nodeIconSize |> max 0)
    )


v2Clamp : V2.Vec2 -> V2.Vec2 -> V2.Vec2 -> V2.Vec2
v2Clamp minV maxV v =
    V2.vec2
        (clamp (V2.getX minV) (V2.getX maxV) (V2.getX v))
        (clamp (V2.getY minV) (V2.getY maxV) (V2.getY v))


nodeSummary : { a | selected : Set G.NodeId, char : G.Character } -> List ( Int, G.NodeType )
nodeSummary { selected, char } =
    char.graph.nodes
        |> Dict.filter (\id nodeType -> Set.member id selected)
        |> Dict.values
        |> List.map .val
        |> List.sortBy .name
        |> List.Extra.group
        |> List.map (\( head, tail ) -> ( List.length tail + 1, head ))
        |> List.sortBy
            (\( count, nodeType ) ->
                -1
                    * (count
                        -- I really can't sort on a tuple, Elm? Sigh.
                        + (case nodeType.quality of
                            G.Keystone ->
                                1000000

                            G.Notable ->
                                1000

                            G.Plain ->
                                0
                          )
                      )
            )


statsSummary : { a | selected : Set G.NodeId, char : G.Character, game : G.GameVersionData } -> List GS.StatTotal
statsSummary g =
    nodeSummary g
        |> List.concatMap (\( count, node ) -> node.stats |> List.map (\( stat, level ) -> ( stat, count * level )))
        |> GS.calcStats g.game.stats


type alias StatsSummary =
    { selected : Set G.NodeId
    , char : G.Character
    , game : G.GameVersionData
    , nodes : List ( Int, G.NodeType )
    , stats : List GS.StatTotal
    , params : Route.HomeParams
    }


parseStatsSummary : Model -> Route.HomeParams -> Result String StatsSummary
parseStatsSummary model params =
    Graph.parse model.gameData params
        |> Result.map
            (Tuple.first
                >> (\m ->
                        { selected = m.selected
                        , char = m.char
                        , game = m.game
                        , nodes = nodeSummary m
                        , stats = statsSummary m
                        , params = params
                        }
                   )
            )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Browser.Events.onResize (\w h -> WindowSize w h |> Resize)
        , Draggable.subscriptions DragMsg model.drag
        , Ports.saveFileContentRead SaveFileImport
        ]


dragConfig : Draggable.Config () Msg
dragConfig =
    Draggable.basicConfig (\( x, y ) -> V2.vec2 x y |> OnDragBy)
