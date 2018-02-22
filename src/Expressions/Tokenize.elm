module Expressions.Tokenize
    exposing
        ( identifier
        , operator
        , token
        , tokens
        , lines
        , tokenize
        , Token(..)
        , Operator(..)
        , Url(..)
        , MathFunction(..)
        , HttpFunction(..)
        , urlToString
        )

{-| Tokenize


# Types

@docs Token, Value, Operator


# Functions

@docs tokenize

-}

import Parser exposing (..)
import Parser.LanguageKit exposing (variable)
import Char
import Set exposing (Set)
import JsonValue exposing (JsonValue(..))


type MathFunction
    = Sine
    | Cosine
    | Tangent
    | Turns


type HttpFunction
    = GetJson


type Operator
    = Add
    | Subtract
    | Multiply
    | Divide
    | Exponentiate
    | EqualTo
    | LessThan Bool
    | GreaterThan Bool
    | MathModule MathFunction
    | HttpModule HttpFunction


type Url
    = Https String
    | Mailto String
    | Tel String
    | Math String
    | Time String
    | Other String String


type Token
    = Identifier String
    | Value JsonValue
    | Operator Operator
    | Url Url



-- type Type
--     = Float
--     | String
--     | Bool
--     | Unknown
-- type Expression t
--     = Get String t
--     | Use JsonValue
--     | Comparison Operator (Expression Unknown) (Expression Unknown)
--     | Math Float Operator (List (Expression Float))
--     | MathFunction String (Expression Float)
--     | If (Expression Bool) (Expression t) (Expression t)


isIdentifierHeadChar : Char -> Bool
isIdentifierHeadChar c =
    Char.isLower c
        || c
        == '.'
        || c
        == '_'


isIdentifierTailChar : Char -> Bool
isIdentifierTailChar c =
    Char.isLower c
        || Char.isUpper c
        || Char.isDigit c
        || c
        == '.'
        || c
        == '_'


notIdentifiers : Set String
notIdentifiers =
    ["true", "false"]
        |> Set.fromList


identifier : Parser Token
identifier =
    variable isIdentifierHeadChar isIdentifierTailChar notIdentifiers
        |> map Identifier


schemeAndStringToUrl : String -> String -> Url
schemeAndStringToUrl scheme string =
    case scheme of
        "https" ->
            Https string
        
        "mailto" ->
            Mailto string
        
        "tel" ->
            Tel string
        
        "math" ->
            Math string
        
        "time" ->
            Time string
        
        _ ->
            Other scheme string


urlToString : Url -> String
urlToString url =
    case url of
        Https string ->
            "https:" ++ string
        
        Mailto email ->
            "mailto:" ++ email
        
        Tel phone ->
            "tel:" ++ phone
        
        Math string ->
            "math:" ++ string
        
        Time string ->
            "time:" ++ string
        
        Other scheme string ->
            scheme ++ ":" ++ string


whitespaceChars : Set Char
whitespaceChars =
    [' ', '\n', '\r', '\t']
        |> Set.fromList


url : Parser Token
url =
    delayedCommitMap schemeAndStringToUrl
        (keep oneOrMore Char.isLower |. symbol ":")
        (keep oneOrMore (\c -> Set.member c whitespaceChars |> not))
        |> map Url


operator : Parser Operator
operator =
    oneOf
        [ succeed Add
            |. symbol "+"
        , succeed Subtract
            |. symbol "-"
        , succeed Exponentiate
            |. symbol "**"
        , succeed Multiply
            |. symbol "*"
        , succeed Divide
            |. symbol "/"
        , succeed EqualTo
            |. symbol "=="
        , succeed (LessThan True)
            |. symbol "<="
        , succeed (LessThan False)
            |. symbol "<"
        , succeed (GreaterThan True)
            |. symbol ">="
        , succeed (GreaterThan False)
            |. symbol ">"
        , succeed (MathModule Sine)
            |. keyword "Math.sin"
        , succeed (MathModule Cosine)
            |. keyword "Math.cos"
        , succeed (MathModule Tangent)
            |. keyword "Math.tan"
        , succeed (MathModule Turns)
            |. keyword "Math.turns"
        , succeed (HttpModule GetJson)
            |. keyword "HTTP.get_json"
        ]


value : Parser JsonValue
value =
    oneOf
        [ succeed NumericValue
            |= float
        , delayedCommit (symbol "-") <|
            succeed (negate >> NumericValue)
                |= float
        , succeed (BoolValue True)
            |. keyword "true"
        , succeed (BoolValue False)
            |. keyword "false"
        ]


magicNumbers : Parser JsonValue
magicNumbers =
    oneOf
        [ succeed e
            |. keyword "Math.e"
        , succeed pi
            |. keyword "Math.pi"
        ]
        |> map NumericValue


token : Parser Token
token =
    inContext "token" <|
        oneOf
            [ succeed Value
                |= magicNumbers
            , url
            , identifier
            , succeed Value
                |= value
            , succeed Operator
                |= operator
            ]


isSpace : Char -> Bool
isSpace c =
    c == ' '


isNewline : Char -> Bool
isNewline c =
    c == '\n'


spaces : Parser ()
spaces =
    ignore oneOrMore isSpace


optionalSpaces : Parser ()
optionalSpaces =
    ignore zeroOrMore isSpace


newlines : Parser ()
newlines =
    ignore oneOrMore isNewline


optionalNewlines : Parser ()
optionalNewlines =
    ignore zeroOrMore isNewline


nextToken : Parser Token
nextToken =
    delayedCommit optionalSpaces <|
        succeed identity
            |. optionalSpaces
            |= token


tokensHelp : List Token -> Parser (List Token)
tokensHelp revTokens =
    oneOf
        [ nextToken
            |> andThen (\t -> tokensHelp (t :: revTokens))
        , succeed (List.reverse revTokens)
        ]


tokens : Parser (List Token)
tokens =
    inContext "tokens" <|
        succeed identity
            |. optionalSpaces
            |= andThen (\t -> tokensHelp [ t ]) token
            |. optionalSpaces


nextLine : Parser (List Token)
nextLine =
    delayedCommit newlines <|
        succeed identity
            |= tokens


linesHelp : List (List Token) -> Parser (List (List Token))
linesHelp revLines =
    oneOf
        [ nextLine
            |> andThen (\l -> linesHelp (l :: revLines))
        , lazy <|
            \_ -> succeed (List.reverse revLines)
        ]


lines : Parser (List (List Token))
lines =
    inContext "lines" <|
        succeed identity
            |. optionalNewlines
            |= andThen (\l -> linesHelp [ l ]) tokens
            |. optionalNewlines
            |. end


tokenize : String -> Result Error (List (List Token))
tokenize input =
    run lines input
