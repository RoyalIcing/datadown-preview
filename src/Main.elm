module Main exposing (main)

import Browser exposing (UrlRequest)
import Browser.Navigation as Navigation
import Datadown exposing (Content(..), Document, Section(..), sectionHasTitle)
import Datadown.MutationModel as MutationModel
import Datadown.Parse exposing (parseDocument)
import Datadown.Process as Process exposing (Error, Resolved, ResolvedSection(..), processDocument)
import Datadown.QueryModel as QueryModel
import Datadown.Rpc exposing (Rpc)
import Dict exposing (Dict)
import Expressions.Evaluate as Evaluate exposing (evaluateTokenLines)
import Expressions.Tokenize as Tokenize exposing (Token(..), tokenize)
import Html exposing (..)
import Html.Attributes exposing (attribute, checked, class, disabled, href, id, placeholder, rows, style, type_, value)
import Html.Events exposing (onCheck, onClick, onInput)
import Http
import Json.Value exposing (JsonValue(..))
import Parser
import Preview
import Preview.Decorate
import Preview.Json
import Routes exposing (CollectionSource(..), EditMode(..), Route(..), collectionSourceFor)
import Samples
import Services.CollectedSource
import Set exposing (Set)
import Task
import Time
import Url exposing (Url)


type alias Expressions =
    Result Error (List (List Token))


type SourceStatus
    = Loading
    | Loaded


type alias Model =
    { documentSources : Dict String String
    , parsedDocuments : Dict String (Document Expressions)
    , processedDocuments : Dict String (Resolved Evaluate.Error Expressions)
    , route : Route
    , navKey : Navigation.Key
    , sourceStatuses : Dict Routes.CollectionSourceId SourceStatus
    , now : Time.Posix
    , sectionInputs : Dict String JsonValue
    , rpcResponses : Dict Datadown.Rpc.Id (Maybe Datadown.Rpc.Response)
    , mutationHistory : List String
    }


type Error
    = Parser (List Parser.DeadEnd)
    | Evaluate Evaluate.Error
    -- | Process (Process.Error e)


type alias DisplayOptions =
    { compact : Bool
    , hideNoContent : Bool
    , processDocument : Document Expressions -> Resolved Evaluate.Error Expressions
    , sectionInputs : Dict String JsonValue
    , getRpcResponse : Datadown.Rpc.Id -> Maybe (Maybe Datadown.Rpc.Response)
    , contentToJson : Content Expressions -> Result Evaluate.Error JsonValue
    , baseHtmlSource : String
    }


parseExpressions : String -> Result Error (List (List Token))
parseExpressions input =
    case tokenize input of
        Err parserError ->
            Err (Parser parserError)

        Ok tokens ->
            Ok tokens


builtInValueFromModel : Model -> String -> Maybe JsonValue
builtInValueFromModel model key =
    let
        zone =
            Time.utc  
    in
        case key of
            "time:seconds" ->
                model.now
                    |> Time.toSecond zone
                    |> toFloat
                    |> Json.Value.NumericValue
                    >> Just

            "now.date.s" ->
                model.now
                    |> Time.toSecond zone
                    |> toFloat
                    |> Json.Value.NumericValue
                    >> Just

            "now.date.m" ->
                model.now
                    |> Time.toMinute zone
                    |> toFloat
                    |> Json.Value.NumericValue
                    >> Just

            "now.date.h" ->
                model.now
                    |> Time.toHour zone
                    |> toFloat
                    |> Json.Value.NumericValue
                    >> Just

            _ ->
                Nothing


evaluateExpressions : Model -> (String -> Result (Process.Error Evaluate.Error) JsonValue) -> Result Error (List (List Token)) -> Result Evaluate.Error JsonValue
evaluateExpressions model resolveFromDocument parsedExpressions =
    let
        defaultResolveWithModel : String -> Result (Process.Error Evaluate.Error) JsonValue
        defaultResolveWithModel key =
            case resolveFromDocument key of
                Ok value ->
                    Ok value

                Err error ->
                    case builtInValueFromModel model key of
                        Just value ->
                            Ok value

                        Nothing ->
                            Err error

        resolveWithModel : String -> Result (Process.Error Evaluate.Error) JsonValue
        resolveWithModel key =
            case Dict.get key model.sectionInputs of
                Just (Json.Value.StringValue "") ->
                    defaultResolveWithModel key

                Just value ->
                    Ok value

                Nothing ->
                    defaultResolveWithModel key
    in
        case parsedExpressions of
            Err error ->
                case error of
                    Parser deadEnds ->
                        Err <| Evaluate.Parsing ("Could not parse: " ++ Debug.toString deadEnds)

                    Evaluate evaluateError ->
                        Err <| Evaluate.Parsing ("Could not parse: " ++ Debug.toString evaluateError)

            Ok expressions ->
                evaluateTokenLines resolveWithModel expressions


valueForRpcID : Model -> String -> List String -> JsonValue -> Result Evaluate.Error JsonValue
valueForRpcID model id keyPath json =
    let
        maybeMaybeResponse =
            Dict.get id model.rpcResponses
    in
    case keyPath of
        "params" :: otherKeys ->
            json
                |> Json.Value.getIn keyPath
                >> Result.mapError Evaluate.NoValueForIdentifier

        "result" :: otherKeys ->
            case maybeMaybeResponse of
                Just (Just response) ->
                    response.result
                        |> Result.mapError Evaluate.Rpc
                        |> Result.andThen (Json.Value.getIn otherKeys >> Result.mapError Evaluate.NoValueForIdentifier)

                _ ->
                    Ok Json.Value.NullValue

        "error" :: otherKeys ->
            case maybeMaybeResponse of
                Just (Just response) ->
                    case response.result of
                        Err error ->
                            error
                                |> Datadown.Rpc.errorToJsonValue
                                |> Json.Value.getIn otherKeys
                                >> Result.mapError Evaluate.NoValueForIdentifier

                        _ ->
                            Ok Json.Value.NullValue

                _ ->
                    Ok Json.Value.NullValue

        _ ->
            Err (Evaluate.NoValueForIdentifier (String.join "." keyPath))


contentToJson : Model -> Content Expressions -> Result Evaluate.Error JsonValue
contentToJson model content =
    case content of
        Text text ->
            Ok <| Json.Value.StringValue text

        Json json ->
            Ok json

        Expressions lines ->
            case lines of
                Ok (((Value value) :: []) :: []) ->
                    Ok value

                _ ->
                    Err Evaluate.CannotConvertToJson

        List items ->
            items
                |> List.filterMap (Tuple.first >> contentToJson model >> Result.toMaybe)
                |> Json.Value.ArrayValue
                |> Ok

        Code maybeLanguage source ->
            String.trim source
                |> Json.Value.StringValue
                |> Ok

        Reference id keyPath json ->
            valueForRpcID model id keyPath json

        _ ->
            Err Evaluate.CannotConvertToJson


type alias Flags =
    {}


modelWithDocumentProcessed : String -> Model -> Model
modelWithDocumentProcessed key model =
    case Dict.get key model.documentSources of
        Just source ->
            let
                parsed =
                    parseDocument parseExpressions source

                processed =
                    processDocumentWithModel model parsed

                parsedDocuments =
                    Dict.insert key parsed model.parsedDocuments

                processedDocuments =
                    Dict.insert key processed model.processedDocuments
            in
            { model
                | parsedDocuments = parsedDocuments
                , processedDocuments = processedDocuments
            }

        Nothing ->
            model


modelWithCurrentDocumentProcessed : Model -> Model
modelWithCurrentDocumentProcessed model =
    case model.route of
        CollectionItem source key _ ->
            modelWithDocumentProcessed key model

        _ ->
            model


init : Flags -> Url -> Navigation.Key -> ( Model, Cmd Message )
init flags url navKey =
    let
        route =
            Routes.parseUrl url

        ( sourceStatuses, documentSources, commands ) =
            case collectionSourceFor route of
                Just (GitHubRepo owner repo branch) ->
                    ( Dict.singleton
                        (GitHubRepo owner repo branch |> Routes.collectionSourceToId)
                        Loading
                    , Dict.empty
                    , [ Services.CollectedSource.listDocuments owner repo branch
                            |> Task.attempt (LoadedGitHubComponents owner repo branch)
                      ]
                    )

                Just Tour ->
                    ( Dict.singleton
                        (Tour |> Routes.collectionSourceToId)
                        Loaded
                    , Samples.tourDocumentSources
                    , []
                    )

                _ ->
                    ( Dict.empty, Dict.empty, [] )

        model =
            { documentSources = documentSources
            , parsedDocuments = Dict.empty
            , processedDocuments = Dict.empty
            , route = route
            , navKey = navKey
            , sourceStatuses = sourceStatuses
            , now = Time.millisToPosix 0
            , sectionInputs = Dict.empty
            , rpcResponses = Dict.empty
            , mutationHistory = []
            }
                |> (case route of
                        CollectionItem _ key _ ->
                            modelWithDocumentProcessed key

                        _ ->
                            identity
                   )
    in
    ( model
    , Cmd.batch commands
    )


type Message
    = NavigateTo Browser.UrlRequest
    | UrlChanged Url
    | ChangeDocumentSource String
    | GoToDocumentsList
    | GoToPreviousDocument
    | GoToNextDocument
    | GoToDocumentWithKey CollectionSource String
    | GoToContentSources CollectionSource
    | NewDocument
    | ChangeSectionInput String JsonValue
    | Time Time.Posix
    | BeginLoading
    | BeginRpcWithID String Bool
    | RpcResponded Datadown.Rpc.Response
    | LoadedGitHubComponents String String String (Result Http.Error (List Services.CollectedSource.ContentInfo))
    | RunMutation String


update : Message -> Model -> ( Model, Cmd Message )
update msg model =
    case msg of
        NavigateTo location ->
            ( model , Cmd.none )
        
        UrlChanged url ->
            ( model , Cmd.none )

        ChangeDocumentSource newInput ->
            let
                newModel =
                    case model.route of
                        CollectionItem source key _ ->
                            let
                                documentSources =
                                    model.documentSources
                                        |> Dict.insert key newInput
                            in
                            { model | documentSources = documentSources }
                                |> modelWithDocumentProcessed key

                        _ ->
                            model
            in
            ( newModel
            , Cmd.none
            )

        GoToDocumentsList ->
            let
                route =
                    case model.route of
                        Collection collection ->
                            Collection collection

                        CollectionItem collection _ _ ->
                            Collection collection

                        _ ->
                            Landing
            in
            ( { model | route = route }
            , Navigation.pushUrl model.navKey <| Routes.toPath route
            )

        GoToPreviousDocument ->
            case model.route of
                CollectionItem collection key editMode ->
                    case String.toInt key of
                        Just index ->
                            let
                                newIndex =
                                    max 0 (index - 1)

                                newKey =
                                    String.fromInt newIndex

                                newRoute =
                                    CollectionItem collection newKey editMode

                                newModel =
                                    { model | route = newRoute }
                                        |> modelWithDocumentProcessed newKey
                            in
                            ( newModel
                            , Navigation.pushUrl model.navKey <| Routes.toPath newRoute
                            )

                        Nothing ->
                            ( model , Cmd.none )

                _ ->
                    ( model
                    , Cmd.none
                    )

        GoToNextDocument ->
            case model.route of
                CollectionItem collection key editMode ->
                    case String.toInt key of
                        Just index ->
                            let
                                maxIndex =
                                    Dict.size model.documentSources - 1

                                newIndex =
                                    min maxIndex (index + 1)

                                newKey =
                                    String.fromInt newIndex

                                newRoute =
                                    CollectionItem collection newKey editMode

                                newModel =
                                    { model | route = newRoute }
                                        |> modelWithDocumentProcessed newKey
                            in
                            ( newModel
                            , Navigation.pushUrl model.navKey <| Routes.toPath newRoute
                            )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model
                    , Cmd.none
                    )

        GoToDocumentWithKey collection key ->
            let
                newRoute =
                    CollectionItem collection key WithPreview

                newModel =
                    { model | route = newRoute }
                        |> modelWithDocumentProcessed key
            in
            ( newModel
            , Navigation.pushUrl model.navKey (Routes.toPath newRoute)
            )

        GoToContentSources collection ->
            let
                newRoute =
                    CollectionContentSources collection

                newModel =
                    { model | route = newRoute }
            in
            ( newModel
            , Navigation.pushUrl model.navKey (Routes.toPath newRoute)
            )

        NewDocument ->
            let
                currentIndex =
                    case model.route of
                        CollectionItem collection key editMode ->
                            String.toInt key
                                |> Maybe.withDefault 0

                        _ ->
                            0

                newDocumentSource =
                    "# Untitled"

                documentSources =
                    model.documentSources
                        |> Dict.insert "new" newDocumentSource
            in
            ( { model
                | documentSources = documentSources
                , parsedDocuments = Dict.empty
                , processedDocuments = Dict.empty
              }
            , Cmd.none
            )

        ChangeSectionInput sectionTitle newValue ->
            let
                newSectionInputs =
                    case String.split ":" sectionTitle of
                        head :: tail ->
                            model.sectionInputs
                                |> Dict.insert head newValue

                        _ ->
                            model.sectionInputs

                newModel =
                    { model | sectionInputs = newSectionInputs }
            in
            ( modelWithCurrentDocumentProcessed newModel
            , Cmd.none
            )

        Time time ->
            let
                newModel =
                    case model.route of
                        CollectionItem collection key _ ->
                            let
                                modelWithTime =
                                    { model | now = time }

                                maybeParsed =
                                    case Dict.get key model.parsedDocuments of
                                        Just parsed ->
                                            Just ( True, parsed )

                                        Nothing ->
                                            case Dict.get key model.documentSources of
                                                Just source ->
                                                    Just ( False, parseDocument parseExpressions source )

                                                Nothing ->
                                                    Nothing
                            in
                            case maybeParsed of
                                Just ( cached, parsed ) ->
                                    let
                                        processed =
                                            processDocumentWithModel model parsed

                                        parsedDocuments =
                                            if cached then
                                                model.parsedDocuments

                                            else
                                                Dict.insert key parsed model.parsedDocuments

                                        processedDocuments =
                                            Dict.insert key processed model.processedDocuments
                                    in
                                    { model
                                        | parsedDocuments = parsedDocuments
                                        , processedDocuments = processedDocuments
                                        , now = time
                                    }

                                Nothing ->
                                    model

                        _ ->
                            model
            in
            ( newModel, Cmd.none )

        BeginLoading ->
            let
                maybeResolvedDocument =
                    case model.route of
                        CollectionItem collection key _ ->
                            Dict.get key model.processedDocuments

                        _ ->
                            Nothing

                rpcsFromSection : ( String, ResolvedSection (Process.Error Evaluate.Error) Expressions ) -> List (Rpc String)
                rpcsFromSection ( title, ResolvedSection section ) =
                    section.rpcs

                rpcs =
                    case maybeResolvedDocument of
                        Just resolved ->
                            resolved.sections
                                |> List.concatMap rpcsFromSection

                        Nothing ->
                            []

                rpcToCommandAndId rpc =
                    case Datadown.Rpc.toCommand RpcResponded rpc of
                        Just command ->
                            Just ( rpc.id, command )

                        Nothing ->
                            Nothing

                ( ids, commands ) =
                    rpcs
                        |> List.filterMap rpcToCommandAndId
                        |> List.unzip

                emptyResponses =
                    List.repeat (List.length ids) Nothing
                        |> List.map2 (\a b -> ( a, b )) ids
                        |> Dict.fromList

                rpcResponses =
                    model.rpcResponses
                        |> Dict.union emptyResponses

                newModel =
                    modelWithCurrentDocumentProcessed { model | rpcResponses = rpcResponses }
            in
            ( newModel
            , Cmd.batch commands
            )

        BeginRpcWithID id reload ->
            let
                maybeResolvedDocument =
                    case model.route of
                        CollectionItem collection key _ ->
                            Dict.get key model.processedDocuments

                        _ ->
                            Nothing

                rpcsFromSection : ( String, ResolvedSection (Process.Error Evaluate.Error) Expressions ) -> List (Rpc String)
                rpcsFromSection ( title, ResolvedSection section ) =
                    section.rpcs

                rpcs =
                    case maybeResolvedDocument of
                        Just resolved ->
                            resolved.sections
                                |> List.concatMap rpcsFromSection

                        Nothing ->
                            []

                maybeRpc =
                    rpcs
                        |> List.filter (\rpc -> rpc.id == id)
                        |> List.head
            in
            case maybeRpc of
                Just rpc ->
                    case Datadown.Rpc.toCommand RpcResponded rpc of
                        Just command ->
                            let
                                rpcResponses =
                                    Dict.insert id Nothing model.rpcResponses
                            in
                            ( modelWithCurrentDocumentProcessed { model | rpcResponses = rpcResponses }
                            , command
                            )

                        Nothing ->
                            ( model
                            , Cmd.none
                            )

                Nothing ->
                    ( model
                    , Cmd.none
                    )

        RpcResponded response ->
            let
                rpcResponses =
                    Dict.insert response.id (Just response) model.rpcResponses
            in
            ( modelWithCurrentDocumentProcessed { model | rpcResponses = rpcResponses }
            , Cmd.none
            )

        LoadedGitHubComponents owner repo branch result ->
            case result of
                Ok contentInfos ->
                    let
                        documentSources =
                            contentInfos
                                |> List.filterMap (\r -> r.content |> Maybe.map (\content -> ( r.path, content )))
                                |> Dict.fromList

                        sourceStatuses =
                            model.sourceStatuses
                                |> Dict.insert (GitHubRepo owner repo branch |> Routes.collectionSourceToId)
                                    Loaded
                    in
                    ( { model
                        | documentSources = documentSources
                        , sourceStatuses = sourceStatuses
                      }
                    , Cmd.none
                    )

                Err error ->
                    Debug.todo "Error loading GitHub components!"

        RunMutation name ->
            ( { model
                | mutationHistory = name :: model.mutationHistory
              }
            , Cmd.none
            )


subscriptions : Model -> Sub Message
subscriptions model =
    Sub.batch
        [ Time.every 1000 Time
        ]


row : Html.Attribute msg
row =
    class "flex flex-row"


col : Html.Attribute msg
col =
    class "flex flex-col"


buttonStyle : String -> Html.Attribute msg
buttonStyle color =
    class <| "inline-block px-4 py-2 text-bold no-underline text-white bg-" ++ color ++ " rounded"


open : Bool -> Html.Attribute msg
open flag =
    if flag then
        attribute "open" ""

    else
        class ""


viewExpressionToken : Token -> Html Message
viewExpressionToken token =
    case token of
        Identifier identifier ->
            div [] [ text identifier ]

        Value value ->
            div [] [ text (Debug.toString value) ]

        Operator operator ->
            div [] [ text (Debug.toString operator) ]

        Tokenize.Url url ->
            div [] [ text (Debug.toString url) ]


viewExpression : List Token -> Html Message
viewExpression tokens =
    div [] (tokens |> List.map viewExpressionToken)


showCodeForLanguage : Maybe String -> Bool
showCodeForLanguage language =
    case language of
        Just "json" ->
            False

        _ ->
            True


viewCode : DisplayOptions -> Maybe String -> String -> Html Message
viewCode options maybeLanguage source =
    let
        sourcePrefix =
            case maybeLanguage of
                Just "html" ->
                    options.baseHtmlSource

                _ ->
                    ""

        maybePreviewHtml =
            Preview.view maybeLanguage (sourcePrefix ++ "\n" ++ source)

        sourceIsOpen =
            maybePreviewHtml == Nothing
    in
    if not options.compact && showCodeForLanguage maybeLanguage then
        div []
            [ div [] [ maybePreviewHtml |> Maybe.withDefault (text "") ]
            , details [ class "mt-2", open sourceIsOpen ]
                [ summary [ class "px-2 py-1 font-mono text-xs italic text-purple-darker border border-purple-lightest cursor-pointer" ]
                    [ text ("Source" ++ (Maybe.map ((++) " ") maybeLanguage |> Maybe.withDefault "")) ]
                , pre [ class "overflow-auto px-2 py-2 text-purple-darker bg-purple-lightest" ]
                    [ code [ class "font-mono text-xs" ] [ text source ] ]
                ]
            ]

    else
        div [] [ maybePreviewHtml |> Maybe.withDefault (text "") ]


viewRpc : Rpc String -> Maybe (Maybe Datadown.Rpc.Response) -> Html Message
viewRpc rpc maybeResponse =
    let
        loadButton =
            button [ onClick <| BeginRpcWithID rpc.id True, class "w-full text-left" ] [ text "Load" ]

        ( loadingClasses, responseStatusHtml, maybeResponseHtml ) =
            case maybeResponse of
                Nothing ->
                    ( "bg-yellow-lighter", loadButton, Nothing )

                Just Nothing ->
                    ( "bg-orange-lighter", text "Loading…", Nothing )

                Just (Just response) ->
                    case response.result of
                        Ok json ->
                            ( "bg-green-lighter", span [ class "summary-indicator-inline" ] [ text "Success" ], Just <| Preview.Json.viewJson json )

                        Err error ->
                            let
                                statusText =
                                    [ "Error:"
                                    , String.fromInt error.code
                                    , error.message
                                    ]
                                        |> String.join " "
                            in
                            ( "bg-red-lighter", span [ class "summary-indicator-inline" ] [ text statusText ], Maybe.map Preview.Json.viewJson error.data )
    in
    div []
        [ details []
            [ summary [ class "flex justify-between px-2 py-1 font-mono text-xs italic text-white bg-grey-darker cursor-pointer" ]
                [ span [ class "pr-2 summary-indicator-inline" ] [ text rpc.method ]
                , span [] [ text rpc.id ]
                ]
            , rpc.params
                |> Maybe.map Preview.Json.viewJson
                |> Maybe.withDefault (text "")
            ]
        , case maybeResponseHtml of
            Just responseHtml ->
                details []
                    [ summary [ class "flex justify-between px-2 py-1 font-mono text-xs italic cursor-pointer", class loadingClasses ]
                        [ responseStatusHtml ]
                    , responseHtml
                    ]

            Nothing ->
                div [ class "flex justify-between px-2 py-1 font-mono text-xs italic", class loadingClasses ]
                    [ responseStatusHtml ]
        ]


viewContent : DisplayOptions -> Content (Result Error (List (List Token))) -> Html Message
viewContent options content =
    case content of
        Text s ->
            div [ class "font-sans w-full" ] (Preview.Decorate.view s)

        Code (Just "graphql") query ->
            let
                rpc =
                    Datadown.Rpc.graphQL query
            in
            div []
                [ viewCode options (Just "graphql") query
                , viewRpc rpc (options.getRpcResponse rpc.id)
                ]

        Code language source ->
            viewCode options language source

        Json json ->
            let
                maybeRpc =
                    Datadown.Rpc.fromJsonValue json
            in
            case maybeRpc of
                Just rpc ->
                    viewRpc rpc (options.getRpcResponse rpc.id)

                Nothing ->
                    Preview.Json.viewJson json

        Expressions expressionsResult ->
            case expressionsResult of
                Err expressionsError ->
                    h3 [ class "px-2 py-1 text-white bg-red-dark" ] [ text <| Debug.toString expressionsError ]

                Ok expressions ->
                    pre [ class "px-2 py-2 text-teal-darker bg-teal-lightest" ]
                        [ code [ class "font-mono text-sm" ] (List.map viewExpression expressions) ]

        List items ->
            ul [] (List.map (\( item, qualifier ) -> li [] [ viewContent options item ]) items)

        Quote document ->
            let
                resolved =
                    options.processDocument document
            in
            resolved.sections
                |> List.map makeSectionViewModel
                |> List.map (viewSection [] options)
                |> div [ class "pl-6 border-l border-teal" ]

        Reference id keyPath json ->
            div [] [ text "Reference: ", cite [] [ text <| Debug.toString id ] ]


viewContentResult : DisplayOptions -> Result (Process.Error Evaluate.Error) (Content (Result Error (List (List Token)))) -> Html Message
viewContentResult options contentResult =
    case contentResult of
        Err error ->
            case error of
                _ ->
                    div [ class "mb-3 px-2 py-1 text-white bg-red-dark" ] [ text (Debug.toString error) ]

        Ok content ->
            div [ class "mb-3" ] [ viewContent options content ]


viewContentResults : DisplayOptions -> List String -> String -> List (Result (Process.Error Evaluate.Error) (Content Expressions)) -> List b -> List (Html Message)
viewContentResults options parentPath sectionTitle contentResults subsections =
    let
        showNothing =
            List.isEmpty contentResults && options.hideNoContent

        hasSubsections =
            not <| List.isEmpty subsections

        showEditor =
            if String.contains ":" sectionTitle then
                True

            else if List.isEmpty contentResults then
                not hasSubsections

            else
                False
    in
    if showNothing then
        []

    else if showEditor then
        let
            ( baseTitle, kind ) =
                case String.split ":" sectionTitle of
                    head :: second :: rest ->
                        ( head, String.trim second )

                    head :: [] ->
                        ( head, "text" )

                    [] ->
                        ( "", "" )

            isSingular =
                kind == "text"

            key =
                baseTitle
                    :: parentPath
                    |> List.reverse
                    |> String.join "."

            jsonToStrings json =
                case json of
                    StringValue s ->
                        [ s ]

                    NumericValue f ->
                        [ String.fromFloat f ]

                    BoolValue b ->
                        if b then
                            [ "✅" ]

                        else
                            [ "❎" ]

                    ArrayValue items ->
                        items
                            |> List.concatMap jsonToStrings

                    _ ->
                        []

            defaultValues : List String
            defaultValues =
                contentResults
                    |> List.filterMap Result.toMaybe
                    |> List.filterMap (options.contentToJson >> Result.toMaybe)
                    |> List.concatMap jsonToStrings

            choiceCount =
                List.length defaultValues

            stringValue =
                case Dict.get key options.sectionInputs of
                    Nothing ->
                        if choiceCount > 1 then
                            defaultValues |> List.head |> Maybe.withDefault ""

                        else
                            ""

                    Just (StringValue s) ->
                        s

                    Just json ->
                        if isSingular then
                            jsonToStrings json |> List.head |> Maybe.withDefault ""

                        else
                            jsonToStrings json |> String.join "\n"

            optionHtmlFor string =
                option [ value string ] [ text string ]
        in
        if hasSubsections then
            []

        else if kind == "bool" then
            [ label
                [ class "block" ]
                [ input
                    [ type_ "checkbox"
                    , onCheck (Json.Value.BoolValue >> ChangeSectionInput key)
                    ]
                    []
                , text " "
                , text baseTitle
                ]
            ]

        else if choiceCount > 1 then
            [ select
                [ value stringValue
                , onInput (Json.Value.StringValue >> ChangeSectionInput key)
                , class "w-full mb-3 px-2 py-1 control rounded"
                ]
                (List.map optionHtmlFor defaultValues)
            ]

        else
            let
                rowCount =
                    case kind of
                        "number" ->
                            1

                        _ ->
                            3
            in
            [ textarea
                [ value stringValue
                , placeholder (String.join "\n" defaultValues)
                , onInput (Json.Value.StringValue >> ChangeSectionInput key)
                , rows rowCount
                , class "w-full mb-3 px-2 py-1 control rounded-sm"
                ]
                []
            ]

    else
        contentResults
            |> List.map (viewContentResult options)


type alias SectionViewModel e =
    { title : String
    , mainContent : List (Result e (Content (Result Error (List (List Token)))))
    , subsections : List ( String, ResolvedSection e (Result Error (List (List Token))) )
    }


makeSectionViewModel : ( String, ResolvedSection e (Result Error (List (List Token))) ) -> SectionViewModel e
makeSectionViewModel ( title, resolvedSection ) =
    case resolvedSection of
        ResolvedSection record ->
            SectionViewModel title record.mainContent record.subsections


viewSectionTitle : Int -> List (Html.Html msg) -> Html.Html msg
viewSectionTitle level =
    case level of
        0 ->
            h2 [ class "mb-2 text-xl text-blue-dark cursor-pointer summary-indicator-absolute" ]

        1 ->
            h3 [ class "mb-2 text-lg text-blue-dark cursor-pointer summary-indicator-absolute" ]

        2 ->
            h4 [ class "mb-2 text-base text-blue-dark cursor-pointer summary-indicator-absolute" ]

        _ ->
            h5 [ class "mb-2 text-sm text-blue-dark cursor-pointer summary-indicator-absolute" ]


viewSection : List String -> DisplayOptions -> SectionViewModel (Process.Error Evaluate.Error) -> Html Message
viewSection sectionPath options { title, mainContent, subsections } =
    details [ attribute "open" "" ]
        [ summary []
            [ viewSectionTitle (List.length sectionPath) [ text title ]
            ]
        , viewContentResults options sectionPath title mainContent subsections
            |> div []
        , subsections
            |> List.map makeSectionViewModel
            |> List.map (viewSection (title :: sectionPath) options)
            |> div [ class "ml-2" ]

        -- , div [] [ text (variables |> toString) ]
        ]


viewFontAwesomeIcon : String -> Html Message
viewFontAwesomeIcon id =
    i [ class ("fas fa-" ++ id) ] []


viewDocumentNavigation : Model -> Html Message
viewDocumentNavigation model =
    div
        [ class "h-8 bg-indigo-darkest"
        ]
        [ case model.route of
            Collection collection ->
                div [ row, class "px-2 h-8 justify-between" ]
                    [ button [ onClick NewDocument, class "px-2 py-1 text-indigo-lightest" ] [ viewFontAwesomeIcon "plus", text " New" ]
                    , button [ class "px-2 py-1 text-indigo-lightest rounded-sm" ] [ viewFontAwesomeIcon "share", text " Export" ]
                    ]

            CollectionItem collection key editMode ->
                div [ row, class "h-8 self-end flex-shrink justify-between items-center" ]
                    [ button [ onClick GoToDocumentsList, class "px-2 py-1 text-white" ] [ viewFontAwesomeIcon "list" ]
                    , div [ class "py-1 text-center font-bold text-white" ] [ text key ]
                    , button [ onClick BeginLoading, class "px-2 py-1 text-yellow-lighter" ] [ viewFontAwesomeIcon "arrow-circle-down" ]
                    ]

            _ ->
                text ""
        ]


viewNavListItem : String -> Bool -> Message -> Html Message
viewNavListItem title active clickMsg =
    h2 [ class "" ]
        [ button
            [ class "w-full px-4 py-2 text-left text-base font-bold cursor-default"
            , if active then
                class "text-indigo-darkest bg-blue-light"

              else
                class "text-white bg-indigo-darkest"
            , onClick clickMsg
            ]
            [ text title ]
        ]


viewListInner : CollectionSource -> Model -> Maybe String -> Html Message
viewListInner collection model activeKey =
    let
        viewItem key documentSource =
            viewNavListItem key (Just key == activeKey) (GoToDocumentWithKey collection key)

        innerHtmls =
            case Dict.get (Routes.collectionSourceToId collection) model.sourceStatuses of
                Just Loaded ->
                    Dict.map viewItem model.documentSources |> Dict.values

                Just Loading ->
                    let
                        message =
                            case collection of
                                GitHubRepo owner repoName branch ->
                                    "Loading @" ++ owner ++ "/" ++ repoName ++ "/" ++ branch ++ " from GitHub…"

                                Tour ->
                                    "Loading Tours…"
                    in
                    [ h2 [ class "mt-3" ]
                        [ text message ]
                    ]

                _ ->
                    []
    in
    div [ class "bg-indigo-darkest" ]
        innerHtmls


viewCollectionConfigLinks : Route -> CollectionSource -> Html Message
viewCollectionConfigLinks route collection =
    let
        contentSourcesActive =
            route == CollectionContentSources collection
    in
    div [ class "pt-4 bg-indigo-darkest" ]
        [ viewNavListItem "Import content" contentSourcesActive (GoToContentSources collection)
        ]


viewCollectionSummary : CollectionSource -> Html Message
viewCollectionSummary collection =
    let
        message =
            case collection of
                GitHubRepo owner repoName branch ->
                    span [ class "font-sm" ]
                        [ text <| "@" ++ owner ++ " " ++ repoName ++ " " ++ branch ++ " from GitHub"
                        ]

                Tour ->
                    text "Tour"
    in
    div [ class "pt-3 pb-4 px-4 bg-indigo-darkest" ]
        [ h2 [ class "text-sm text-white" ] [ message ]
        ]


processDocumentWithModel : Model -> Document (Result Error (List (List Token))) -> Resolved Evaluate.Error (Result Error (List (List Token)))
processDocumentWithModel model document =
    processDocument (evaluateExpressions model) (contentToJson model) document


viewQueryField : QueryModel.FieldDefinition -> Html Message
viewQueryField field =
    dl
        [ class "mb-3" ]
        [ dt [ class "text-xl font-bold text-purple mb-2" ] [ text field.name ]
        , dd []
            [ case field.value of
                QueryModel.StringValue valueResult constraints ->
                    case valueResult of
                        Ok maybeS ->
                            div [ class "p-1 bg-grey-lighter" ] [ text (Maybe.withDefault "" maybeS) ]

                        Err error ->
                            case error of
                                QueryModel.NotInChoices s choices ->
                                    div [ class "p-1 text-red border-l-4 border-red" ] [ text s ]

                QueryModel.BoolValue b ->
                    div
                        [ class "italic" ]
                        [ text
                            (if b then
                                "true"

                             else
                                "false"
                            )
                        ]

                QueryModel.IntValue i ->
                    div
                        [ class "italic" ]
                        [ text (String.fromInt i) ]

                QueryModel.StringsArrayValue strings ->
                    ol
                        [ class "ml-4" ]
                        (List.map (text >> List.singleton >> li [ class "mb-2" ]) strings)

                _ ->
                    text ""
            ]
        ]


viewMutationField : QueryModel.FieldDefinition -> Html Message
viewMutationField field =
    let
        argCount =
            case field.argDefinitions of
                QueryModel.ArgsDefinition args ->
                    List.length args
    in
    button
        [ class "px-2 py-1 mb-1 text-white bg-green rounded-sm border border-green-dark"
        , onClick (RunMutation field.name)
        ]
        [ text field.name
        , text <|
            if argCount > 0 then
                "…"

            else
                ""
        ]


viewMutationHistory : List String -> Html Message
viewMutationHistory mutationNames =
    details [ class "mb-8", open True ]
        [ summary [ class "font-bold text-green" ]
            [ text ("Mutation history (" ++ (List.length mutationNames |> Debug.toString) ++ ")")
            ]
        , ol [ class "ml-4" ]
            (mutationNames
                |> List.map (text >> List.singleton >> li [ class "" ])
                |> List.reverse
            )
        ]


specialSectionTitles : Set String
specialSectionTitles =
    Set.fromList [ "Query", "Mutation" ]


viewDocumentPreview : Model -> Resolved Evaluate.Error Expressions -> Html Message
viewDocumentPreview model resolved =
    let
        displayOptions : DisplayOptions
        displayOptions =
            { compact = False
            , hideNoContent = False
            , processDocument = processDocumentWithModel model
            , sectionInputs = model.sectionInputs
            , getRpcResponse = (\b a -> Dict.get a b) model.rpcResponses
            , contentToJson = contentToJson model
            , baseHtmlSource =
                Dict.get "components/base.html" model.documentSources
                    |> Maybe.withDefault ""
            }

        sectionsHtml : List (Html Message)
        sectionsHtml =
            resolved.sections
                |> List.filter (\( title, _ ) -> not <| Set.member title specialSectionTitles)
                |> List.map makeSectionViewModel
                |> List.map (viewSection [] displayOptions)

        sectionWithTitle titleToFind =
            resolved.sections
                |> List.filter (\( title, _ ) -> title == titleToFind)
                |> List.head
                |> Maybe.map Tuple.second

        typeNameMatchesTitle typeName title =
            String.startsWith (typeName ++ ":") title

        sectionDefiningType typeName =
            resolved.sections
                |> List.filter (\( title, _ ) -> typeNameMatchesTitle typeName title)
                |> List.head

        contentToJson2 =
            contentToJson model >> Result.mapError Process.Evaluate

        maybeQueryModel =
            sectionWithTitle "Query"
                |> Maybe.map (QueryModel.parseQueryModel contentToJson2 sectionDefiningType)

        maybeQueryModelWithValues =
            case ( maybeQueryModel, sectionWithTitle "Initial" ) of
                ( Just queryModel, Just initialSection ) ->
                    queryModel
                        |> QueryModel.applyValuesToModel contentToJson2 initialSection
                        |> Just

                ( Just queryModel, Nothing ) ->
                    Just queryModel

                _ ->
                    Nothing

        maybeQueryModelWithMutations =
            case ( maybeQueryModelWithValues, sectionWithTitle "Update" ) of
                ( Just queryModel, Just (ResolvedSection updateSection) ) ->
                    let
                        applyValuesToModel =
                            QueryModel.applyValuesToModel contentToJson2

                        mutationSectionWithName nameToFind =
                            updateSection.subsections
                                |> List.filter (\( title, subsection ) -> title == nameToFind)
                                |> List.head
                                |> Maybe.map Tuple.second

                        applyMutation name targetQueryModel =
                            case mutationSectionWithName name of
                                Just mutationSection ->
                                    applyValuesToModel mutationSection targetQueryModel

                                Nothing ->
                                    targetQueryModel
                    in
                    Just <| List.foldr applyMutation queryModel model.mutationHistory

                _ ->
                    maybeQueryModel

        maybeMutationModel =
            sectionWithTitle "Mutation"
                |> Maybe.map (MutationModel.parseMutationModel contentToJson2 sectionDefiningType)

        introHtml : List (Html Message)
        introHtml =
            viewContentResults
                { displayOptions
                    | compact = True
                    , hideNoContent = True
                }
                []
                "intro"
                resolved.intro
                []
    in
    div [ class "w-1/2 overflow-auto mb-8 pl-4 pb-8 md:pl-6 leading-tight" ]
        [ div [ row, class "mb-4" ]
            [ h1 [ class "flex-1 pt-4 text-3xl text-blue" ] [ text resolved.title ]
            ]
        , div [ class "pr-4" ] introHtml
        , case maybeQueryModelWithMutations of
            Just queryModel ->
                div [ col, class "mb-4 mr-4" ]
                    (List.map viewQueryField queryModel.fields)

            Nothing ->
                text ""
        , case maybeMutationModel of
            Just mutationModel ->
                div [ col, class "mb-4 mr-4" ]
                    (List.map viewMutationField mutationModel.fields)

            Nothing ->
                text ""
        , case maybeMutationModel of
            Just mutationModel ->
                viewMutationHistory model.mutationHistory

            Nothing ->
                text ""
        , div [ class "pr-4" ] sectionsHtml
        ]


viewDocumentSource : Model -> String -> Resolved Evaluate.Error Expressions -> Html Message
viewDocumentSource model documentSource resolvedDocument =
    let
        editorHtml =
            case model.route of
                CollectionItem _ _ Off ->
                    text ""

                _ ->
                    div [ class "flex-1 min-w-full md:min-w-0" ]
                        [ textarea [ value documentSource, onInput ChangeDocumentSource, class "fixed flex-1 w-2/5 h-full overflow-auto pt-4 pl-4 font-mono text-sm leading-normal text-indigo-darkest bg-blue-lightest", rows 20 ] []
                        ]

        previewHtml =
            case model.route of
                CollectionItem _ _ Only ->
                    text ""

                _ ->
                    viewDocumentPreview model resolvedDocument
    in
    div [ col, class "flex-1 h-screen" ]
        [ div [ row, class "flex-1 flex-wrap h-screen" ]
            [ editorHtml
            , previewHtml
            ]
        ]


view : Model -> Browser.Document Message
view model =
    { title = "Datadown"
    , body = [ viewBody model ]
    }


viewBody : Model -> Html Message
viewBody model =
    div [ class "flex justify-center flex-1" ]
        [ case model.route of
            Collection collection ->
                let
                    documentView =
                        div [] []

                    listView =
                        div [ class "w-1/5" ]
                            [ div [ class "fixed w-1/5 h-full overflow-auto bg-indigo-darkest" ]
                                [ viewCollectionSummary collection
                                , viewListInner collection model Nothing
                                , viewCollectionConfigLinks model.route collection
                                ]
                            ]
                in
                div [ row, class "flex-1" ]
                    [ listView
                    , documentView
                    ]

            CollectionContentSources collection ->
                let
                    field url alias =
                        div [ row, class "mb-4" ]
                            [ label [ col, class "flex-grow" ]
                                [ span [ class "font-bold" ] [ text "URL" ]
                                , input [ class "flex-1 mt-1 px-2 py-1 mr-2 border", value url ] []
                                ]
                            , label [ col ]
                                [ span [ class "font-bold" ] [ text "Alias" ]
                                , input [ class "flex-1 mt-1 px-2 py-1 border font-mono", value alias ] []
                                ]
                            ]

                    documentView =
                        div [ class "flex-1 p-4" ]
                            [ h1 [ class "mb-4" ]
                                [ text "Import content" ]
                            , p [ class "mb-8" ]
                                [ text "Work with content from GitHub and Trello." ]
                            , div [ col ]
                                [ field "https://trello.com/b/4wctPH1u" "collectedIA"
                                , field "" ""
                                , button [ class "flex-shrink mt-4 px-2 py-2 text-white bg-black rounded" ] [ text "Update" ]
                                ]
                            ]

                    listView =
                        div [ class "w-1/5" ]
                            [ div [ class "fixed w-1/5 h-full bg-indigo-darkest" ]
                                [ viewCollectionSummary collection
                                , viewListInner collection model Nothing
                                , viewCollectionConfigLinks model.route collection
                                ]
                            ]
                in
                div [ row, class "flex-1" ]
                    [ listView
                    , documentView
                    ]

            CollectionItem collection key _ ->
                let
                    documentView =
                        Maybe.map2
                            (viewDocumentSource model)
                            (Dict.get key model.documentSources)
                            (Dict.get key model.processedDocuments)
                            |> Maybe.withDefault (div [] [ text <| "No document #" ++ key ])

                    listView =
                        div [ class "w-1/5" ]
                            [ div [ class "fixed w-1/5 h-full bg-indigo-darkest" ]
                                [ viewCollectionSummary collection
                                , viewListInner collection model (Just key)
                                , viewCollectionConfigLinks model.route collection
                                ]
                            ]
                in
                div [ row, class "flex-1" ]
                    [ listView
                    , documentView
                    ]

            _ ->
                div [ col, class "flex flex-row flex-1 max-w-sm p-4 text-center text-grey-darkest" ]
                    [ h1 [ class "mb-2 text-center" ]
                        [ text "Prototype rich functionality, in your browser" ]
                    , h2 [ class "mb-4 text-center font-normal  " ]
                        [ text "Design screens, components, and interactivity. With real APIs." ]
                    , h3 [] [ a [ href "/tour", buttonStyle "purple-dark", class "mb-2" ] [ text "See examples" ] ]
                    , h3 [] [ a [ href "/github/RoyalIcing/lofi-bootstrap/master", buttonStyle "purple-dark", class "mb-2" ] [ text "Bootstrap 4 components" ] ]
                    ]

        -- , div [ class "fixed pin-b pin-l flex pb-4 pl-4 md:pl-6" ]
        --     [ button [ class "px-2 py-1 text-purple-lightest bg-purple" ] [ text "Edit" ]
        --     , button [ class "px-2 py-1 text-purple-dark bg-purple-lightest" ] [ text "Test" ]
        --     , button [ class "px-2 py-1 text-purple-dark bg-purple-lightest" ] [ text "Export" ]
        --     ]
        ]


main : Program Flags Model Message
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlRequest = NavigateTo
        , onUrlChange = UrlChanged
        }
