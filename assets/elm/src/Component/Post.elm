module Component.Post exposing (Model, Msg(..), ViewConfig, checkableView, expandReplyComposer, handleEditorEventReceived, handleReplyCreated, init, postNodeId, setup, teardown, update, view)

import Actor exposing (Actor)
import Avatar exposing (personAvatar)
import Color exposing (Color)
import Connection exposing (Connection)
import Dict exposing (Dict)
import File exposing (File)
import Flash
import Globals exposing (Globals)
import Group exposing (Group)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Icons
import Id exposing (Id)
import Json.Decode as Decode exposing (Decoder, field, maybe, string)
import Markdown
import Mutation.ClosePost as ClosePost
import Mutation.CreatePostReaction as CreatePostReaction
import Mutation.CreateReply as CreateReply
import Mutation.CreateReplyReaction as CreateReplyReaction
import Mutation.DeletePostReaction as DeletePostReaction
import Mutation.DeleteReplyReaction as DeleteReplyReaction
import Mutation.DismissPosts as DismissPosts
import Mutation.MarkAsRead as MarkAsRead
import Mutation.RecordReplyViews as RecordReplyViews
import Mutation.ReopenPost as ReopenPost
import Mutation.UpdatePost as UpdatePost
import Mutation.UpdateReply as UpdateReply
import Post exposing (Post)
import PostEditor exposing (PostEditor)
import Query.Replies
import RenderedHtml
import Reply exposing (Reply)
import Repo exposing (Repo)
import Route
import Route.Group
import Route.SpaceUser
import Scroll
import Session exposing (Session)
import Space exposing (Space)
import SpaceUser exposing (SpaceUser)
import Subscription.PostSubscription as PostSubscription
import Task exposing (Task)
import Time exposing (Posix, Zone)
import ValidationError
import Vendor.Keys as Keys exposing (Modifier(..), enter, esc, onKeydown, preventDefault)
import View.Helpers exposing (onPassiveClick, setFocus, smartFormatTime, unsetFocus, viewIf, viewUnless)



-- MODEL


type alias Model =
    { id : String
    , spaceSlug : String
    , postId : Id
    , replyIds : Connection Id
    , replyComposer : PostEditor
    , postEditor : PostEditor
    , replyEditors : ReplyEditors
    , isChecked : Bool
    }


type alias Data =
    { post : Post
    , author : Actor
    }


type alias ReplyEditors =
    Dict Id PostEditor


resolveData : Repo -> Model -> Maybe Data
resolveData repo model =
    let
        maybePost =
            Repo.getPost model.postId repo
    in
    case maybePost of
        Just post ->
            Maybe.map2 Data
                (Just post)
                (Repo.getActor (Post.authorId post) repo)

        Nothing ->
            Nothing



-- LIFECYCLE


init : String -> Id -> Connection Id -> Model
init spaceSlug postId replyIds =
    Model
        postId
        spaceSlug
        postId
        replyIds
        (PostEditor.init postId)
        (PostEditor.init postId)
        Dict.empty
        False


setup : Model -> Cmd Msg
setup model =
    PostSubscription.subscribe model.postId


teardown : Model -> Cmd Msg
teardown model =
    PostSubscription.unsubscribe model.postId



-- UPDATE


type Msg
    = NoOp
    | ExpandReplyComposer
    | NewReplyBodyChanged String
    | NewReplyFileAdded File
    | NewReplyFileUploadProgress Id Int
    | NewReplyFileUploaded Id Id String
    | NewReplyFileUploadError Id
    | NewReplyBlurred
    | NewReplySubmit
    | NewReplyAndCloseSubmit
    | NewReplyEscaped
    | NewReplySubmitted (Result Session.Error ( Session, CreateReply.Response ))
    | PreviousRepliesRequested
    | PreviousRepliesFetched (Result Session.Error ( Session, Query.Replies.Response ))
    | ReplyViewsRecorded (Result Session.Error ( Session, RecordReplyViews.Response ))
    | SelectionToggled
    | DismissClicked
    | Dismissed (Result Session.Error ( Session, DismissPosts.Response ))
    | MoveToInboxClicked
    | PostMovedToInbox (Result Session.Error ( Session, MarkAsRead.Response ))
    | ExpandPostEditor
    | CollapsePostEditor
    | PostEditorBodyChanged String
    | PostEditorFileAdded File
    | PostEditorFileUploadProgress Id Int
    | PostEditorFileUploaded Id Id String
    | PostEditorFileUploadError Id
    | PostEditorSubmitted
    | PostUpdated (Result Session.Error ( Session, UpdatePost.Response ))
    | ExpandReplyEditor Id
    | CollapseReplyEditor Id
    | ReplyEditorBodyChanged Id String
    | ReplyEditorFileAdded Id File
    | ReplyEditorFileUploadProgress Id Id Int
    | ReplyEditorFileUploaded Id Id Id String
    | ReplyEditorFileUploadError Id Id
    | ReplyEditorSubmitted Id
    | ReplyUpdated Id (Result Session.Error ( Session, UpdateReply.Response ))
    | CreatePostReactionClicked
    | DeletePostReactionClicked
    | PostReactionCreated (Result Session.Error ( Session, CreatePostReaction.Response ))
    | PostReactionDeleted (Result Session.Error ( Session, DeletePostReaction.Response ))
    | CreateReplyReactionClicked Id
    | DeleteReplyReactionClicked Id
    | ReplyReactionCreated Id (Result Session.Error ( Session, CreateReplyReaction.Response ))
    | ReplyReactionDeleted Id (Result Session.Error ( Session, DeleteReplyReaction.Response ))
    | ClosePostClicked
    | ReopenPostClicked
    | PostClosed (Result Session.Error ( Session, ClosePost.Response ))
    | PostReopened (Result Session.Error ( Session, ReopenPost.Response ))


update : Msg -> Id -> Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
update msg spaceId globals model =
    case msg of
        NoOp ->
            noCmd globals model

        ExpandReplyComposer ->
            expandReplyComposer globals spaceId model

        NewReplyBodyChanged val ->
            let
                newReplyComposer =
                    PostEditor.setBody val model.replyComposer
            in
            ( ( { model | replyComposer = newReplyComposer }
              , PostEditor.saveLocal newReplyComposer
              )
            , globals
            )

        NewReplyFileAdded file ->
            noCmd globals { model | replyComposer = PostEditor.addFile file model.replyComposer }

        NewReplyFileUploadProgress clientId percentage ->
            noCmd globals { model | replyComposer = PostEditor.setFileUploadPercentage clientId percentage model.replyComposer }

        NewReplyFileUploaded clientId fileId url ->
            let
                newReplyComposer =
                    model.replyComposer
                        |> PostEditor.setFileState clientId (File.Uploaded fileId url)

                cmd =
                    newReplyComposer
                        |> PostEditor.insertFileLink fileId
            in
            ( ( { model | replyComposer = newReplyComposer }, cmd ), globals )

        NewReplyFileUploadError clientId ->
            noCmd globals { model | replyComposer = PostEditor.setFileState clientId File.UploadError model.replyComposer }

        NewReplySubmit ->
            let
                newModel =
                    { model | replyComposer = PostEditor.setToSubmitting model.replyComposer }

                body =
                    PostEditor.getBody model.replyComposer

                cmd =
                    globals.session
                        |> CreateReply.request spaceId model.postId body (PostEditor.getUploadIds model.replyComposer)
                        |> Task.attempt NewReplySubmitted
            in
            ( ( newModel, cmd ), globals )

        NewReplyAndCloseSubmit ->
            let
                newModel =
                    { model | replyComposer = PostEditor.setToSubmitting model.replyComposer }

                body =
                    PostEditor.getBody model.replyComposer

                replyCmd =
                    globals.session
                        |> CreateReply.request spaceId model.postId body (PostEditor.getUploadIds model.replyComposer)
                        |> Task.attempt NewReplySubmitted

                closeCmd =
                    globals.session
                        |> ClosePost.request spaceId model.postId
                        |> Task.attempt PostClosed
            in
            ( ( newModel, Cmd.batch [ replyCmd, closeCmd ] ), globals )

        NewReplySubmitted (Ok ( newSession, reply )) ->
            let
                ( newReplyComposer, cmd ) =
                    model.replyComposer
                        |> PostEditor.reset

                newModel =
                    { model | replyComposer = newReplyComposer }
            in
            ( ( newModel
              , Cmd.batch
                    [ setFocus (PostEditor.getTextareaId model.replyComposer) NoOp
                    , cmd
                    ]
              )
            , { globals | session = newSession }
            )

        NewReplySubmitted (Err Session.Expired) ->
            redirectToLogin globals model

        NewReplySubmitted (Err _) ->
            noCmd globals model

        NewReplyEscaped ->
            if PostEditor.getBody model.replyComposer == "" then
                ( ( { model | replyComposer = PostEditor.collapse model.replyComposer }
                  , unsetFocus (PostEditor.getTextareaId model.replyComposer) NoOp
                  )
                , globals
                )

            else
                noCmd globals model

        NewReplyBlurred ->
            noCmd globals model

        PreviousRepliesRequested ->
            case Connection.startCursor model.replyIds of
                Just cursor ->
                    let
                        cmd =
                            globals.session
                                |> Query.Replies.request spaceId model.postId cursor 10
                                |> Task.attempt PreviousRepliesFetched
                    in
                    ( ( model, cmd ), globals )

                Nothing ->
                    noCmd globals model

        PreviousRepliesFetched (Ok ( newSession, resp )) ->
            let
                maybeFirstReplyId =
                    Connection.head model.replyIds

                newReplyIds =
                    Connection.prependConnection resp.replyIds model.replyIds

                newGlobals =
                    { globals
                        | session = newSession
                        , repo = Repo.union resp.repo globals.repo
                    }

                newModel =
                    { model | replyIds = newReplyIds }

                viewCmd =
                    markVisibleRepliesAsViewed newGlobals spaceId newModel
            in
            ( ( newModel, Cmd.batch [ viewCmd ] ), newGlobals )

        PreviousRepliesFetched (Err Session.Expired) ->
            redirectToLogin globals model

        PreviousRepliesFetched (Err _) ->
            noCmd globals model

        ReplyViewsRecorded (Ok ( newSession, _ )) ->
            noCmd { globals | session = newSession } model

        ReplyViewsRecorded (Err Session.Expired) ->
            redirectToLogin globals model

        ReplyViewsRecorded (Err _) ->
            noCmd globals model

        SelectionToggled ->
            ( ( { model | isChecked = not model.isChecked }
              , markVisibleRepliesAsViewed globals spaceId model
              )
            , globals
            )

        DismissClicked ->
            let
                cmd =
                    globals.session
                        |> DismissPosts.request spaceId [ model.postId ]
                        |> Task.attempt Dismissed
            in
            ( ( model, cmd ), globals )

        Dismissed (Ok ( newSession, _ )) ->
            ( ( model, Cmd.none )
            , { globals
                | session = newSession
                , flash = Flash.set Flash.Notice "Dismissed from inbox" 3000 globals.flash
              }
            )

        Dismissed (Err Session.Expired) ->
            redirectToLogin globals model

        Dismissed (Err _) ->
            noCmd globals model

        MoveToInboxClicked ->
            let
                cmd =
                    globals.session
                        |> MarkAsRead.request spaceId [ model.postId ]
                        |> Task.attempt PostMovedToInbox
            in
            ( ( model, cmd ), globals )

        PostMovedToInbox (Ok ( newSession, _ )) ->
            ( ( model, Cmd.none )
            , { globals
                | session = newSession
                , flash = Flash.set Flash.Notice "Moved to inbox" 3000 globals.flash
              }
            )

        PostMovedToInbox (Err Session.Expired) ->
            redirectToLogin globals model

        PostMovedToInbox (Err _) ->
            noCmd globals model

        ExpandPostEditor ->
            case resolveData globals.repo model of
                Just data ->
                    let
                        nodeId =
                            PostEditor.getTextareaId model.postEditor

                        newPostEditor =
                            model.postEditor
                                |> PostEditor.expand
                                |> PostEditor.setBody (Post.body data.post)
                                |> PostEditor.setFiles (Post.files data.post)
                                |> PostEditor.clearErrors

                        cmd =
                            Cmd.batch
                                [ setFocus nodeId NoOp
                                ]
                    in
                    ( ( { model | postEditor = newPostEditor }, cmd ), globals )

                Nothing ->
                    noCmd globals model

        CollapsePostEditor ->
            let
                newPostEditor =
                    model.postEditor
                        |> PostEditor.collapse
            in
            ( ( { model | postEditor = newPostEditor }, Cmd.none ), globals )

        PostEditorBodyChanged val ->
            let
                newPostEditor =
                    model.postEditor
                        |> PostEditor.setBody val
            in
            noCmd globals { model | postEditor = newPostEditor }

        PostEditorFileAdded file ->
            let
                newPostEditor =
                    model.postEditor
                        |> PostEditor.addFile file
            in
            noCmd globals { model | postEditor = newPostEditor }

        PostEditorFileUploadProgress clientId percentage ->
            let
                newPostEditor =
                    model.postEditor
                        |> PostEditor.setFileUploadPercentage clientId percentage
            in
            noCmd globals { model | postEditor = newPostEditor }

        PostEditorFileUploaded clientId fileId url ->
            let
                newPostEditor =
                    model.postEditor
                        |> PostEditor.setFileState clientId (File.Uploaded fileId url)

                cmd =
                    newPostEditor
                        |> PostEditor.insertFileLink fileId
            in
            ( ( { model | postEditor = newPostEditor }, cmd ), globals )

        PostEditorFileUploadError clientId ->
            let
                newPostEditor =
                    model.postEditor
                        |> PostEditor.setFileState clientId File.UploadError
            in
            noCmd globals { model | postEditor = newPostEditor }

        PostEditorSubmitted ->
            let
                cmd =
                    globals.session
                        |> UpdatePost.request spaceId model.postId (PostEditor.getBody model.postEditor)
                        |> Task.attempt PostUpdated

                newPostEditor =
                    model.postEditor
                        |> PostEditor.setToSubmitting
                        |> PostEditor.clearErrors
            in
            ( ( { model | postEditor = newPostEditor }, cmd ), globals )

        PostUpdated (Ok ( newSession, UpdatePost.Success post )) ->
            let
                newGlobals =
                    { globals | session = newSession, repo = Repo.setPost post globals.repo }

                newPostEditor =
                    model.postEditor
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.collapse
            in
            ( ( { model | postEditor = newPostEditor }, Cmd.none ), newGlobals )

        PostUpdated (Ok ( newSession, UpdatePost.Invalid errors )) ->
            let
                newPostEditor =
                    model.postEditor
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.setErrors errors
            in
            ( ( { model | postEditor = newPostEditor }, Cmd.none ), globals )

        PostUpdated (Err Session.Expired) ->
            redirectToLogin globals model

        PostUpdated (Err _) ->
            let
                newPostEditor =
                    model.postEditor
                        |> PostEditor.setNotSubmitting
            in
            ( ( { model | postEditor = newPostEditor }, Cmd.none ), globals )

        ExpandReplyEditor replyId ->
            case Repo.getReply replyId globals.repo of
                Just reply ->
                    let
                        newReplyEditor =
                            model.replyEditors
                                |> getReplyEditor replyId
                                |> PostEditor.expand
                                |> PostEditor.setBody (Reply.body reply)
                                |> PostEditor.setFiles (Reply.files reply)
                                |> PostEditor.clearErrors

                        nodeId =
                            PostEditor.getTextareaId newReplyEditor

                        cmd =
                            Cmd.batch
                                [ setFocus nodeId NoOp
                                ]

                        newReplyEditors =
                            model.replyEditors
                                |> Dict.insert replyId newReplyEditor
                    in
                    ( ( { model | replyEditors = newReplyEditors }, cmd ), globals )

                Nothing ->
                    noCmd globals model

        CollapseReplyEditor replyId ->
            let
                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.collapse

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, Cmd.none ), globals )

        ReplyEditorBodyChanged replyId val ->
            let
                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.setBody val

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, Cmd.none ), globals )

        ReplyEditorFileAdded replyId file ->
            let
                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.addFile file

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, Cmd.none ), globals )

        ReplyEditorFileUploadProgress replyId clientId percentage ->
            let
                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.setFileUploadPercentage clientId percentage

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, Cmd.none ), globals )

        ReplyEditorFileUploaded replyId clientId fileId url ->
            let
                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.setFileState clientId (File.Uploaded fileId url)

                cmd =
                    newReplyEditor
                        |> PostEditor.insertFileLink fileId

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, cmd ), globals )

        ReplyEditorFileUploadError replyId clientId ->
            let
                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.setFileState clientId File.UploadError

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, Cmd.none ), globals )

        ReplyEditorSubmitted replyId ->
            let
                replyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId

                cmd =
                    globals.session
                        |> UpdateReply.request spaceId replyId (PostEditor.getBody replyEditor)
                        |> Task.attempt (ReplyUpdated replyId)

                newReplyEditor =
                    replyEditor
                        |> PostEditor.setToSubmitting
                        |> PostEditor.clearErrors

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, cmd ), globals )

        ReplyUpdated replyId (Ok ( newSession, UpdateReply.Success reply )) ->
            let
                newGlobals =
                    { globals | session = newSession, repo = Repo.setReply reply globals.repo }

                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.collapse

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, Cmd.none ), newGlobals )

        ReplyUpdated replyId (Ok ( newSession, UpdateReply.Invalid errors )) ->
            let
                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.setErrors errors

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, Cmd.none ), globals )

        ReplyUpdated replyId (Err Session.Expired) ->
            redirectToLogin globals model

        ReplyUpdated replyId (Err _) ->
            let
                newReplyEditor =
                    model.replyEditors
                        |> getReplyEditor replyId
                        |> PostEditor.setNotSubmitting

                newReplyEditors =
                    model.replyEditors
                        |> Dict.insert replyId newReplyEditor
            in
            ( ( { model | replyEditors = newReplyEditors }, Cmd.none ), globals )

        CreatePostReactionClicked ->
            let
                variables =
                    CreatePostReaction.variables spaceId model.postId

                cmd =
                    globals.session
                        |> CreatePostReaction.request variables
                        |> Task.attempt PostReactionCreated
            in
            ( ( model, cmd ), globals )

        PostReactionCreated (Ok ( newSession, CreatePostReaction.Success post )) ->
            let
                newGlobals =
                    { globals | repo = Repo.setPost post globals.repo, session = newSession }
            in
            ( ( model, Cmd.none ), newGlobals )

        PostReactionCreated (Err Session.Expired) ->
            redirectToLogin globals model

        PostReactionCreated _ ->
            ( ( model, Cmd.none ), globals )

        DeletePostReactionClicked ->
            let
                variables =
                    DeletePostReaction.variables spaceId model.postId

                cmd =
                    globals.session
                        |> DeletePostReaction.request variables
                        |> Task.attempt PostReactionDeleted
            in
            ( ( model, cmd ), globals )

        PostReactionDeleted (Ok ( newSession, DeletePostReaction.Success post )) ->
            let
                newGlobals =
                    { globals | repo = Repo.setPost post globals.repo, session = newSession }
            in
            ( ( model, Cmd.none ), newGlobals )

        PostReactionDeleted (Err Session.Expired) ->
            redirectToLogin globals model

        PostReactionDeleted _ ->
            ( ( model, Cmd.none ), globals )

        CreateReplyReactionClicked replyId ->
            let
                variables =
                    CreateReplyReaction.variables spaceId model.postId replyId

                cmd =
                    globals.session
                        |> CreateReplyReaction.request variables
                        |> Task.attempt (ReplyReactionCreated replyId)
            in
            ( ( model, cmd ), globals )

        ReplyReactionCreated _ (Ok ( newSession, CreateReplyReaction.Success reply )) ->
            let
                newGlobals =
                    { globals | repo = Repo.setReply reply globals.repo, session = newSession }
            in
            ( ( model, Cmd.none ), newGlobals )

        ReplyReactionCreated _ (Err Session.Expired) ->
            redirectToLogin globals model

        ReplyReactionCreated _ _ ->
            ( ( model, Cmd.none ), globals )

        DeleteReplyReactionClicked replyId ->
            let
                variables =
                    DeleteReplyReaction.variables spaceId model.postId replyId

                cmd =
                    globals.session
                        |> DeleteReplyReaction.request variables
                        |> Task.attempt (ReplyReactionDeleted replyId)
            in
            ( ( model, cmd ), globals )

        ReplyReactionDeleted _ (Ok ( newSession, DeleteReplyReaction.Success reply )) ->
            let
                newGlobals =
                    { globals | repo = Repo.setReply reply globals.repo, session = newSession }
            in
            ( ( model, Cmd.none ), newGlobals )

        ReplyReactionDeleted _ (Err Session.Expired) ->
            redirectToLogin globals model

        ReplyReactionDeleted _ _ ->
            ( ( model, Cmd.none ), globals )

        ClosePostClicked ->
            let
                cmd =
                    globals.session
                        |> ClosePost.request spaceId model.postId
                        |> Task.attempt PostClosed
            in
            ( ( { model | replyComposer = PostEditor.setToSubmitting model.replyComposer }, cmd ), globals )

        ReopenPostClicked ->
            let
                cmd =
                    globals.session
                        |> ReopenPost.request spaceId model.postId
                        |> Task.attempt PostReopened
            in
            ( ( { model | replyComposer = PostEditor.setToSubmitting model.replyComposer }, cmd ), globals )

        PostClosed (Ok ( newSession, ClosePost.Success post )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setPost post
            in
            ( ( { model | replyComposer = PostEditor.setNotSubmitting model.replyComposer }, Cmd.none )
            , { globals | repo = newRepo, session = newSession }
            )

        PostClosed (Ok ( newSession, ClosePost.Invalid errors )) ->
            ( ( { model | replyComposer = PostEditor.setNotSubmitting model.replyComposer }, Cmd.none )
            , { globals | session = newSession }
            )

        PostClosed (Err Session.Expired) ->
            redirectToLogin globals model

        PostClosed (Err _) ->
            noCmd globals model

        PostReopened (Ok ( newSession, ReopenPost.Success post )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setPost post

                newReplyComposer =
                    model.replyComposer
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.expand

                cmd =
                    setFocus (PostEditor.getTextareaId newReplyComposer) NoOp
            in
            ( ( { model | replyComposer = newReplyComposer }, cmd )
            , { globals | repo = newRepo, session = newSession }
            )

        PostReopened (Ok ( newSession, ReopenPost.Invalid errors )) ->
            ( ( { model | replyComposer = PostEditor.setNotSubmitting model.replyComposer }, Cmd.none )
            , { globals | session = newSession }
            )

        PostReopened (Err Session.Expired) ->
            redirectToLogin globals model

        PostReopened (Err _) ->
            noCmd globals model


noCmd : Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
noCmd globals model =
    ( ( model, Cmd.none ), globals )


redirectToLogin : Globals -> Model -> ( ( Model, Cmd Msg ), Globals )
redirectToLogin globals model =
    ( ( model, Route.toLogin ), globals )


markVisibleRepliesAsViewed : Globals -> Id -> Model -> Cmd Msg
markVisibleRepliesAsViewed globals spaceId model =
    let
        ( replies, _ ) =
            visibleReplies globals.repo model.replyIds

        unviewedReplyIds =
            replies
                |> List.filter (\reply -> not (Reply.hasViewed reply))
                |> List.map Reply.id
    in
    if List.length unviewedReplyIds > 0 then
        globals.session
            |> RecordReplyViews.request spaceId unviewedReplyIds
            |> Task.attempt ReplyViewsRecorded

    else
        Cmd.none


expandReplyComposer : Globals -> Id -> Model -> ( ( Model, Cmd Msg ), Globals )
expandReplyComposer globals spaceId model =
    let
        cmd =
            Cmd.batch
                [ setFocus (PostEditor.getTextareaId model.replyComposer) NoOp
                , markVisibleRepliesAsViewed globals spaceId model
                ]

        newModel =
            { model | replyComposer = PostEditor.expand model.replyComposer }
    in
    ( ( newModel, cmd ), globals )



-- EVENT HANDLERS


handleReplyCreated : Reply -> Model -> ( Model, Cmd Msg )
handleReplyCreated reply model =
    if Reply.postId reply == model.postId then
        ( { model | replyIds = Connection.append identity (Reply.id reply) model.replyIds }, Cmd.none )

    else
        ( model, Cmd.none )


handleEditorEventReceived : Decode.Value -> Model -> Model
handleEditorEventReceived value model =
    case PostEditor.decodeEvent value of
        PostEditor.LocalDataFetched id body ->
            if id == PostEditor.getId model.replyComposer then
                let
                    newReplyComposer =
                        PostEditor.setBody body model.replyComposer
                in
                { model | replyComposer = newReplyComposer }

            else
                model

        PostEditor.Unknown ->
            model



-- VIEWS


type alias ViewConfig =
    { globals : Globals
    , space : Space
    , currentUser : SpaceUser
    , now : ( Zone, Posix )
    , spaceUsers : List SpaceUser
    , showGroups : Bool
    }


view : ViewConfig -> Model -> Html Msg
view config model =
    case resolveData config.globals.repo model of
        Just data ->
            resolvedView config model data

        Nothing ->
            text "Something went wrong."


resolvedView : ViewConfig -> Model -> Data -> Html Msg
resolvedView config model data =
    let
        ( zone, posix ) =
            config.now
    in
    div [ id (postNodeId model.postId), class "flex" ]
        [ div [ class "flex-no-shrink mr-4" ] [ Actor.avatar Avatar.Medium data.author ]
        , div [ class "flex-grow min-w-0 leading-normal" ]
            [ div [ class "pb-1 flex items-center flex-wrap" ]
                [ div []
                    [ postAuthorName config.space model.postId data.author
                    , a
                        [ Route.href <| Route.Post (Space.slug config.space) model.postId
                        , class "no-underline whitespace-no-wrap"
                        , rel "tooltip"
                        , title "Expand post"
                        ]
                        [ View.Helpers.time config.now ( zone, Post.postedAt data.post ) [ class "mr-3 text-sm text-dusty-blue" ] ]
                    , viewIf (not (PostEditor.isExpanded model.postEditor) && Post.canEdit data.post) <|
                        button
                            [ class "mr-3 text-sm text-dusty-blue"
                            , onClick ExpandPostEditor
                            ]
                            [ text "Edit" ]
                    ]
                , inboxButton data.post
                ]
            , viewIf config.showGroups <|
                groupsLabel config.space (Repo.getGroups (Post.groupIds data.post) config.globals.repo)
            , viewUnless (PostEditor.isExpanded model.postEditor) <|
                bodyView config.space data.post
            , viewIf (PostEditor.isExpanded model.postEditor) <|
                postEditorView (Space.id config.space) config.spaceUsers model.postEditor
            , div [ class "pb-2 flex items-start" ]
                [ postReactionButton data.post
                ]
            , div [ class "relative" ]
                [ repliesView
                    config.globals.repo
                    config.space
                    data.post
                    config.now
                    model.replyIds
                    config.spaceUsers
                    model.replyEditors
                , replyComposerView (Space.id config.space) config.currentUser data.post config.spaceUsers model
                ]
            ]
        ]


checkableView : ViewConfig -> Model -> Html Msg
checkableView config model =
    div [ class "flex" ]
        [ div [ class "mr-1 py-3 flex-0" ]
            [ label [ class "control checkbox" ]
                [ input
                    [ type_ "checkbox"
                    , class "checkbox"
                    , checked model.isChecked
                    , onClick SelectionToggled
                    ]
                    []
                , span [ class "control-indicator border-dusty-blue" ] []
                ]
            ]
        , div [ class "flex-1" ]
            [ view config model
            ]
        ]



-- PRIVATE POST VIEW FUNCTIONS


inboxButton : Post -> Html Msg
inboxButton post =
    let
        addButton =
            button
                [ class "flex tooltip tooltip-bottom no-outline"
                , onClick MoveToInboxClicked
                , attribute "data-tooltip" "Move to inbox"
                ]
                [ Icons.inbox Icons.Off
                ]

        removeButton =
            button
                [ class "flex tooltip tooltip-bottom no-outline text-sm text-green font-bold"
                , onClick DismissClicked
                , attribute "data-tooltip" "Dismiss from inbox"
                ]
                [ span [ class "inline-block" ] [ Icons.inbox Icons.On ]
                , span [ class "ml-1 hidden sm:inline" ] [ text "Inboxed" ]
                ]
    in
    case Post.inboxState post of
        Post.Excluded ->
            addButton

        Post.Dismissed ->
            addButton

        Post.Read ->
            removeButton

        Post.Unread ->
            removeButton


postAuthorName : Space -> Id -> Actor -> Html Msg
postAuthorName space postId author =
    let
        route =
            case author of
                Actor.User user ->
                    Route.SpaceUser (Route.SpaceUser.init (Space.slug space) (SpaceUser.id user))

                _ ->
                    Route.Post (Space.slug space) postId
    in
    a
        [ Route.href route
        , class "mr-3 no-underline text-dusty-blue-darkest whitespace-no-wrap"
        ]
        [ span [ class "font-bold" ] [ text <| Actor.displayName author ] ]


groupsLabel : Space -> List Group -> Html Msg
groupsLabel space groups =
    case groups of
        [ group ] ->
            div [ class "mb-2 mr-3 text-sm text-dusty-blue-dark" ]
                [ text "Posted in "
                , a
                    [ Route.href (Route.Group (Route.Group.init (Space.slug space) (Group.id group)))
                    , class "no-underline text-dusty-blue-dark font-bold whitespace-no-wrap"
                    ]
                    [ text (Group.name group) ]
                ]

        _ ->
            text ""


bodyView : Space -> Post -> Html Msg
bodyView space post =
    div []
        [ div [ class "markdown pb-2" ] [ RenderedHtml.node (Post.bodyHtml post) ]
        , staticFilesView (Post.files post)
        ]


postEditorView : Id -> List SpaceUser -> PostEditor -> Html Msg
postEditorView spaceId spaceUsers editor =
    let
        config =
            { editor = editor
            , spaceId = spaceId
            , spaceUsers = spaceUsers
            , onFileAdded = PostEditorFileAdded
            , onFileUploadProgress = PostEditorFileUploadProgress
            , onFileUploaded = PostEditorFileUploaded
            , onFileUploadError = PostEditorFileUploadError
            , classList = [ ( "tribute-pin-t", True ) ]
            }
    in
    PostEditor.wrapper config
        [ label [ class "composer my-2 p-3" ]
            [ textarea
                [ id (PostEditor.getTextareaId editor)
                , class "w-full no-outline text-dusty-blue-darkest bg-transparent resize-none leading-normal"
                , placeholder "Edit post..."
                , onInput PostEditorBodyChanged
                , readonly (PostEditor.isSubmitting editor)
                , value (PostEditor.getBody editor)
                , onKeydown preventDefault
                    [ ( [ Meta ], enter, \event -> PostEditorSubmitted )
                    ]
                ]
                []
            , ValidationError.prefixedErrorView "body" "Body" (PostEditor.getErrors editor)
            , PostEditor.filesView editor
            , div [ class "flex justify-end" ]
                [ button
                    [ class "mr-2 btn btn-grey-outline btn-sm"
                    , onClick CollapsePostEditor
                    ]
                    [ text "Cancel" ]
                , button
                    [ class "btn btn-blue btn-sm"
                    , onClick PostEditorSubmitted
                    , disabled (PostEditor.isUnsubmittable editor)
                    ]
                    [ text "Update post" ]
                ]
            ]
        ]



-- PRIVATE REPLY VIEW FUNCTIONS


repliesView : Repo -> Space -> Post -> ( Zone, Posix ) -> Connection String -> List SpaceUser -> ReplyEditors -> Html Msg
repliesView repo space post now replyIds spaceUsers editors =
    let
        ( replies, hasPreviousPage ) =
            visibleReplies repo replyIds
    in
    viewUnless (Connection.isEmptyAndExpanded replyIds) <|
        div []
            [ viewIf hasPreviousPage <|
                button
                    [ class "flex items-center mt-2 mb-4 text-dusty-blue no-underline whitespace-no-wrap"
                    , onClick PreviousRepliesRequested
                    ]
                    [ text "Load more..."
                    ]
            , div [] (List.map (replyView repo now space post editors spaceUsers) replies)
            ]


replyView : Repo -> ( Zone, Posix ) -> Space -> Post -> ReplyEditors -> List SpaceUser -> Reply -> Html Msg
replyView repo (( zone, posix ) as now) space post editors spaceUsers reply =
    let
        replyId =
            Reply.id reply

        editor =
            getReplyEditor replyId editors
    in
    case Repo.getActor (Reply.authorId reply) repo of
        Just author ->
            div
                [ id (replyNodeId replyId)
                , classList [ ( "flex mt-4 relative", True ) ]
                ]
                [ viewUnless (Reply.hasViewed reply) <|
                    div [ class "mr-2 -ml-3 w-1 h-9 rounded pin-t bg-orange flex-no-shrink" ] []
                , div [ class "flex-no-shrink mr-3" ] [ Actor.avatar Avatar.Small author ]
                , div [ class "flex-grow leading-normal" ]
                    [ div [ class "pb-1 flex items-baseline" ]
                        [ replyAuthorName space author
                        , View.Helpers.time now ( zone, Reply.postedAt reply ) [ class "mr-3 text-sm text-dusty-blue whitespace-no-wrap" ]
                        , viewIf (not (PostEditor.isExpanded editor) && Reply.canEdit reply) <|
                            button
                                [ class "text-sm text-dusty-blue"
                                , onClick (ExpandReplyEditor replyId)
                                ]
                                [ text "Edit" ]
                        ]
                    , viewUnless (PostEditor.isExpanded editor) <|
                        div []
                            [ div [ class "markdown pb-2" ]
                                [ RenderedHtml.node (Reply.bodyHtml reply)
                                ]
                            , staticFilesView (Reply.files reply)
                            ]
                    , viewIf (PostEditor.isExpanded editor) <|
                        replyEditorView (Space.id space) replyId spaceUsers editor
                    , div [ class "pb-2 flex items-start" ] [ replyReactionButton reply ]
                    ]
                ]

        Nothing ->
            -- The author was not in the repo as expected, so we can't display the reply
            text ""


replyAuthorName : Space -> Actor -> Html Msg
replyAuthorName space author =
    case author of
        Actor.User user ->
            a
                [ Route.href <| Route.SpaceUser (Route.SpaceUser.init (Space.slug space) (SpaceUser.id user))
                , class "mr-3 font-bold whitespace-no-wrap text-dusty-blue-darkest no-underline"
                ]
                [ text <| Actor.displayName author ]

        _ ->
            span [ class "mr-3 font-bold whitespace-no-wrap" ] [ text <| Actor.displayName author ]


replyEditorView : Id -> Id -> List SpaceUser -> PostEditor -> Html Msg
replyEditorView spaceId replyId spaceUsers editor =
    let
        config =
            { editor = editor
            , spaceId = spaceId
            , spaceUsers = spaceUsers
            , onFileAdded = ReplyEditorFileAdded replyId
            , onFileUploadProgress = ReplyEditorFileUploadProgress replyId
            , onFileUploaded = ReplyEditorFileUploaded replyId
            , onFileUploadError = ReplyEditorFileUploadError replyId
            , classList = [ ( "tribute-pin-t", True ) ]
            }
    in
    PostEditor.wrapper config
        [ label [ class "composer my-2 p-3" ]
            [ textarea
                [ id (PostEditor.getTextareaId editor)
                , class "w-full no-outline text-dusty-blue-darkest bg-transparent resize-none leading-normal"
                , placeholder "Edit reply..."
                , onInput (ReplyEditorBodyChanged replyId)
                , readonly (PostEditor.isSubmitting editor)
                , value (PostEditor.getBody editor)
                , onKeydown preventDefault
                    [ ( [ Meta ], enter, \event -> ReplyEditorSubmitted replyId )
                    ]
                ]
                []
            , ValidationError.prefixedErrorView "body" "Body" (PostEditor.getErrors editor)
            , PostEditor.filesView editor
            , div [ class "flex justify-end" ]
                [ button
                    [ class "mr-2 btn btn-grey-outline btn-sm"
                    , onClick (CollapseReplyEditor replyId)
                    ]
                    [ text "Cancel" ]
                , button
                    [ class "btn btn-blue btn-sm"
                    , onClick (ReplyEditorSubmitted replyId)
                    , disabled (PostEditor.isUnsubmittable editor)
                    ]
                    [ text "Update reply" ]
                ]
            ]
        ]


replyComposerView : Id -> SpaceUser -> Post -> List SpaceUser -> Model -> Html Msg
replyComposerView spaceId currentUser post spaceUsers model =
    if Post.state post == Post.Closed then
        div [ class "flex flex-wrap items-center my-3" ]
            [ div [ class "flex-no-shrink mr-3" ] [ Icons.closedAvatar ]
            , div [ class "flex-no-shrink mr-3 text-base text-green font-bold" ] [ text "Resolved" ]
            , div [ class "flex-no-shrink leading-semi-loose" ]
                [ button
                    [ class "mr-2 my-1 btn btn-grey-outline btn-sm"
                    , onClick ReopenPostClicked
                    ]
                    [ text "Reopen" ]
                , viewIf (Post.inboxState post == Post.Read || Post.inboxState post == Post.Unread) <|
                    button
                        [ class "my-1 btn btn-grey-outline btn-sm"
                        , onClick DismissClicked
                        ]
                        [ text "Dismiss from inbox" ]
                ]
            ]

    else if PostEditor.isExpanded model.replyComposer then
        expandedReplyComposerView spaceId currentUser post spaceUsers model.replyComposer

    else
        replyPromptView currentUser


expandedReplyComposerView : Id -> SpaceUser -> Post -> List SpaceUser -> PostEditor -> Html Msg
expandedReplyComposerView spaceId currentUser post spaceUsers editor =
    let
        config =
            { editor = editor
            , spaceId = spaceId
            , spaceUsers = spaceUsers
            , onFileAdded = NewReplyFileAdded
            , onFileUploadProgress = NewReplyFileUploadProgress
            , onFileUploaded = NewReplyFileUploaded
            , onFileUploadError = NewReplyFileUploadError
            , classList = [ ( "tribute-pin-t", True ) ]
            }
    in
    div [ class "-ml-3 pt-3 sticky pin-b bg-white" ]
        [ PostEditor.wrapper config
            [ div [ class "composer p-0" ]
                [ viewIf (False && (Post.inboxState post == Post.Unread || Post.inboxState post == Post.Read)) <|
                    div [ class "flex rounded-t-lg bg-turquoise border-b border-white px-3 py-2" ]
                        [ span [ class "flex-grow mr-3 text-sm text-white font-bold" ]
                            [ span [ class "mr-2 inline-block" ] [ Icons.inboxWhite ]
                            , text "This post is currently in your inbox."
                            ]
                        , button
                            [ class "flex-no-shrink btn btn-xs btn-turquoise-inverse"
                            , onClick DismissClicked
                            ]
                            [ text "Dismiss from my inbox" ]
                        ]
                , label [ class "flex p-3" ]
                    [ div [ class "flex-no-shrink mr-2" ] [ SpaceUser.avatar Avatar.Small currentUser ]
                    , div [ class "flex-grow" ]
                        [ textarea
                            [ id (PostEditor.getTextareaId editor)
                            , class "p-1 w-full h-10 no-outline bg-transparent text-dusty-blue-darkest resize-none leading-normal"
                            , placeholder "Write a reply..."
                            , onInput NewReplyBodyChanged
                            , onKeydown preventDefault
                                [ ( [ Meta ], enter, \event -> NewReplySubmit )
                                , ( [ Shift, Meta ], enter, \event -> NewReplyAndCloseSubmit )
                                , ( [], esc, \event -> NewReplyEscaped )
                                ]
                            , onBlur NewReplyBlurred
                            , value (PostEditor.getBody editor)
                            , readonly (PostEditor.isSubmitting editor)
                            ]
                            []
                        , PostEditor.filesView editor
                        , div [ class "flex items-baseline justify-end" ]
                            [ viewIf (PostEditor.isUnsubmittable editor) <|
                                button
                                    [ class "mr-2 btn btn-grey-outline btn-sm"
                                    , onClick ClosePostClicked
                                    ]
                                    [ text "Resolve" ]
                            , viewUnless (PostEditor.isUnsubmittable editor) <|
                                button
                                    [ class "mr-2 btn btn-grey-outline btn-sm"
                                    , onClick NewReplyAndCloseSubmit
                                    ]
                                    [ text "Send & Resolve" ]
                            , button
                                [ class "btn btn-blue btn-sm"
                                , onClick NewReplySubmit
                                , disabled (PostEditor.isUnsubmittable editor)
                                ]
                                [ text "Send" ]
                            ]
                        ]
                    ]
                ]
            ]
        ]


replyPromptView : SpaceUser -> Html Msg
replyPromptView currentUser =
    button [ class "flex mt-4 items-center", onClick ExpandReplyComposer ]
        [ div [ class "flex-no-shrink mr-3" ] [ SpaceUser.avatar Avatar.Small currentUser ]
        , div [ class "flex-grow leading-semi-loose text-dusty-blue" ]
            [ text "Reply or resolve..."
            ]
        ]


staticFilesView : List File -> Html msg
staticFilesView files =
    viewUnless (List.isEmpty files) <|
        div [ class "flex flex-wrap pb-2" ] <|
            List.map staticFileView files


staticFileView : File -> Html msg
staticFileView file =
    case File.getState file of
        File.Uploaded id url ->
            a
                [ href url
                , target "_blank"
                , class "flex flex-none items-center mr-4 pb-1 no-underline text-dusty-blue hover:text-blue"
                , rel "tooltip"
                , title "Download file"
                ]
                [ div [ class "mr-2" ] [ File.icon Color.DustyBlue file ]
                , div [ class "text-sm font-bold truncate" ] [ text <| "Download " ++ File.getName file ]
                ]

        _ ->
            text ""



-- REACTIONS


postReactionButton : Post -> Html Msg
postReactionButton post =
    if Post.hasReacted post then
        button
            [ class "flex relative tooltip tooltip-bottom items-center mr-6 no-outline"
            , onClick DeletePostReactionClicked
            , attribute "data-tooltip" "Acknowledge"
            ]
            [ Icons.thumbs Icons.On
            , viewIf (Post.reactionCount post > 0) <|
                div
                    [ class "ml-1 text-green font-bold text-sm"
                    ]
                    [ text <| String.fromInt (Post.reactionCount post) ]
            ]

    else
        button
            [ class "flex relative tooltip tooltip-bottom items-center mr-6 no-outline"
            , onClick CreatePostReactionClicked
            , attribute "data-tooltip" "Acknowledge"
            ]
            [ Icons.thumbs Icons.Off
            , viewIf (Post.reactionCount post > 0) <|
                div
                    [ class "ml-1 text-dusty-blue font-bold text-sm"
                    ]
                    [ text <| String.fromInt (Post.reactionCount post) ]
            ]


replyReactionButton : Reply -> Html Msg
replyReactionButton reply =
    if Reply.hasReacted reply then
        button
            [ class "flex relative tooltip tooltip-bottom items-center mr-6 text-green font-bold no-outline"
            , onClick <| DeleteReplyReactionClicked (Reply.id reply)
            , attribute "data-tooltip" "Acknowledge"
            ]
            [ Icons.thumbs Icons.On
            , viewIf (Reply.reactionCount reply > 0) <|
                div
                    [ class "ml-1 text-green font-bold text-sm"
                    ]
                    [ text <| String.fromInt (Reply.reactionCount reply) ]
            ]

    else
        button
            [ class "flex relative tooltip tooltip-bottom items-center mr-6 text-dusty-blue font-bold no-outline"
            , onClick <| CreateReplyReactionClicked (Reply.id reply)
            , attribute "data-tooltip" "Acknowledge"
            ]
            [ Icons.thumbs Icons.Off
            , viewIf (Reply.reactionCount reply > 0) <|
                div
                    [ class "ml-1 text-dusty-blue font-bold text-sm"
                    ]
                    [ text <| String.fromInt (Reply.reactionCount reply) ]
            ]



-- UTILS


postNodeId : String -> String
postNodeId postId =
    "post-" ++ postId


replyNodeId : String -> String
replyNodeId replyId =
    "reply-" ++ replyId


replyComposerId : String -> String
replyComposerId postId =
    "reply-composer-" ++ postId


visibleReplies : Repo -> Connection Id -> ( List Reply, Bool )
visibleReplies repo replyIds =
    let
        replies =
            Repo.getReplies (Connection.toList replyIds) repo

        hasPreviousPage =
            Connection.hasPreviousPage replyIds
    in
    ( replies, hasPreviousPage )


getReplyEditor : Id -> ReplyEditors -> PostEditor
getReplyEditor replyId editors =
    Dict.get replyId editors
        |> Maybe.withDefault (PostEditor.init replyId)
