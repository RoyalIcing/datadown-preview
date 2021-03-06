module Preview.Json exposing
    ( view
    , viewJson
    )

{-| Preview JSON


## Functions

@docs view

-}

import Html exposing (..)
import Html.Attributes exposing (attribute, class)
import Json.Decode
import Json.Value exposing (JsonValue(..))


viewSymbol : String -> Html msg
viewSymbol symbol =
    span [ class "text-purple-light" ] [ text symbol ]


viewString : String -> List (Html msg)
viewString string =
    [ viewSymbol "\""
    , text string
    , viewSymbol "\""
    ]


viewArrayItem : JsonValue -> Html msg
viewArrayItem value =
    li [ class "mb-1 ml-4 pl-1 text-sm text-purple-light bg-purple-o-10" ] [ viewValue value ]


viewKeyValuePair : ( String, JsonValue ) -> List (Html msg)
viewKeyValuePair ( key, value ) =
    [ dt [ class "text-purple-darker" ] (viewString key ++ [ viewSymbol ":" ])
    , dd [ class "mb-1 ml-2 pl-1 bg-purple-o-10" ] [ viewValue value ]
    ]


viewValue : JsonValue -> Html msg
viewValue json =
    let
        children =
            case json of
                StringValue string ->
                    viewString string

                NumericValue number ->
                    [ text (String.fromFloat number) ]

                BoolValue bool ->
                    [ text
                        (if bool then
                            "true"

                         else
                            "false"
                        )
                    ]

                ArrayValue items ->
                    [ details [ attribute "open" "" ]
                        [ summary [ class "cursor-pointer" ]
                            [ span [ class "text-purple-light summary-indicator-inline" ] [], viewSymbol "[" ]
                        , ol [ class "text-base roman" ] (List.map viewArrayItem items)
                        , viewSymbol "]"
                        ]
                    ]

                ObjectValue items ->
                    [ details [ attribute "open" "" ]
                        [ summary [ class "cursor-pointer summary-indicator-inline" ]
                            [ span [ class "text-purple-light summary-indicator-inline" ] [], viewSymbol "{" ]
                        , dl [ class "ml-2 text-base roman" ] (List.concatMap viewKeyValuePair items)
                        , viewSymbol "}"
                        ]
                    ]

                NullValue ->
                    [ text "null" ]
    in
    div [ class "text-base text-black" ] children


{-| Previews a JSON value as HTML
-}
viewJson : JsonValue -> Html msg
viewJson json =
    div [ class "pt-2 pb-2 pl-2 bg-purple-o-10" ]
        [ viewValue json ]


{-| Previews a JSON string as HTML
-}
view : String -> Html msg
view source =
    let
        result =
            source
                |> Json.Decode.decodeString Json.Value.decoder
    in
    case result of
        Ok jsonValue ->
            div [ class "pt-2 pb-2 pl-2 bg-purple-o-10" ]
                [ viewValue jsonValue ]

        Err error ->
            div [] [ text <| Json.Decode.errorToString error ]
