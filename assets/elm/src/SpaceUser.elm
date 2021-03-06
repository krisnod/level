module SpaceUser exposing (Role(..), SpaceUser, State(..), avatar, decoder, displayName, firstName, fragment, handle, id, lastName, role, roleDecoder, spaceId, state, userId)

import Avatar
import GraphQL exposing (Fragment)
import Html exposing (Html)
import Id exposing (Id)
import Json.Decode as Decode exposing (Decoder, fail, field, int, maybe, string, succeed)
import Json.Decode.Pipeline as Pipeline exposing (required)
import Tutorial exposing (Tutorial)



-- TYPES


type SpaceUser
    = SpaceUser Data


type alias Data =
    { id : Id
    , userId : Id
    , spaceId : Id
    , state : State
    , firstName : String
    , lastName : String
    , handle : String
    , role : Role
    , avatarUrl : Maybe String
    , welcomeTutorial : Maybe Tutorial
    , fetchedAt : Int
    }


type Role
    = Member
    | Owner


type State
    = Active
    | Disabled


fragment : Fragment
fragment =
    GraphQL.toFragment
        """
        fragment SpaceUserFields on SpaceUser {
          id
          userId
          space {
            id
          }
          state
          firstName
          lastName
          handle
          role
          avatarUrl
          welcomeTutorial: tutorial(key: "welcome") {
            ...TutorialFields
          }
          fetchedAt
        }
        """
        [ Tutorial.fragment
        ]



-- ACCESSORS


id : SpaceUser -> Id
id (SpaceUser data) =
    data.id


userId : SpaceUser -> Id
userId (SpaceUser data) =
    data.userId


spaceId : SpaceUser -> Id
spaceId (SpaceUser data) =
    data.spaceId


state : SpaceUser -> State
state (SpaceUser data) =
    data.state


firstName : SpaceUser -> String
firstName (SpaceUser data) =
    data.firstName


lastName : SpaceUser -> String
lastName (SpaceUser data) =
    data.lastName


displayName : SpaceUser -> String
displayName (SpaceUser data) =
    data.firstName ++ " " ++ data.lastName


handle : SpaceUser -> String
handle (SpaceUser data) =
    data.handle


avatar : Avatar.Size -> SpaceUser -> Html msg
avatar size (SpaceUser data) =
    Avatar.personAvatar size data


role : SpaceUser -> Role
role (SpaceUser data) =
    data.role


welcomeTutorial : SpaceUser -> Maybe Tutorial
welcomeTutorial (SpaceUser data) =
    data.welcomeTutorial



-- DECODERS


roleDecoder : Decoder Role
roleDecoder =
    let
        convert : String -> Decoder Role
        convert raw =
            case raw of
                "MEMBER" ->
                    succeed Member

                "OWNER" ->
                    succeed Owner

                _ ->
                    fail "Role not valid"
    in
    Decode.andThen convert string


stateDecoder : Decoder State
stateDecoder =
    let
        convert : String -> Decoder State
        convert raw =
            case raw of
                "ACTIVE" ->
                    succeed Active

                "DISABLED" ->
                    succeed Disabled

                _ ->
                    fail "State not valid"
    in
    Decode.andThen convert string


decoder : Decoder SpaceUser
decoder =
    Decode.map SpaceUser
        (Decode.succeed Data
            |> required "id" Id.decoder
            |> required "userId" Id.decoder
            |> required "space" (field "id" Id.decoder)
            |> required "state" stateDecoder
            |> required "firstName" string
            |> required "lastName" string
            |> required "handle" string
            |> required "role" roleDecoder
            |> required "avatarUrl" (maybe string)
            |> required "welcomeTutorial" (maybe Tutorial.decoder)
            |> required "fetchedAt" int
        )
