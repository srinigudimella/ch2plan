module Route exposing (..)

import Set as Set exposing (Set)
import Navigation
import UrlParser as P exposing ((</>), (<?>))
import Regex


type alias HomeParams =
    { build : Maybe String }


type Route
    = Home HomeParams


type alias Features =
    { multiSelect : Bool }


features0 : Features
features0 =
    { multiSelect = False }


parse : Navigation.Location -> Route
parse =
    hashQS
        >> P.parseHash parser
        >> Maybe.withDefault (Home { build = Nothing })
        >> Debug.log "navigate to"


hashQS : Navigation.Location -> Navigation.Location
hashQS loc =
    -- UrlParser doesn't do ?query=strings in the #hash, so fake it using the non-hash querystring
    case Regex.split (Regex.AtMost 1) (Regex.regex "\\?") loc.hash of
        [ hash ] ->
            { loc | search = loc.search }

        [ hash, qs ] ->
            { loc | hash = hash, search = loc.search ++ "&" ++ qs }

        [] ->
            Debug.crash "hashqs: empty"

        other ->
            Debug.crash "hashqs: 3+"


maybeString =
    P.string
        |> P.map
            (\s ->
                if s == "" then
                    Nothing
                else
                    Just s
            )


parser : P.Parser (Route -> a) a
parser =
    P.oneOf
        [ P.map (Home { build = Nothing }) P.top
        , P.map Home <| P.map HomeParams <| P.s "b" </> maybeString
        ]


falseBools =
    Set.fromList [ "", "0", "no", "n", "false" ]


boolParam : String -> P.QueryParser (Bool -> a) a
boolParam name =
    Maybe.withDefault ""
        >> String.toLower
        >> (flip Set.member) falseBools
        >> not
        |> P.customParam name


parseFeatures : Navigation.Location -> Features
parseFeatures =
    hashQS
        -- parser expects no segments
        >> (\loc -> { loc | hash = "" })
        >> P.parseHash featuresParser
        >> Maybe.withDefault features0
        >> Debug.log "feature-flags: "


featuresParser : P.Parser (Features -> a) a
featuresParser =
    P.map Features <| P.top <?> boolParam "enableMultiSelect"


stringify : Route -> String
stringify route =
    case route of
        Home { build } ->
            case build of
                Nothing ->
                    "#/"

                Just b ->
                    "#/b/" ++ b