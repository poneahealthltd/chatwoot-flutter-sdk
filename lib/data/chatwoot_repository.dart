
import 'dart:async';
import 'dart:convert';
import 'dart:core';

import 'package:chatwoot_client_sdk/chatwoot_callbacks.dart';
import 'package:chatwoot_client_sdk/data/local/entity/chatwoot_user.dart';
import 'package:chatwoot_client_sdk/data/local/local_storage.dart';
import 'package:chatwoot_client_sdk/data/remote/chatwoot_client_exception.dart';
import 'package:chatwoot_client_sdk/data/remote/requests/chatwoot_action_data.dart';
import 'package:chatwoot_client_sdk/data/remote/requests/chatwoot_new_message_request.dart';
import 'package:chatwoot_client_sdk/data/remote/responses/chatwoot_event.dart';
import 'package:chatwoot_client_sdk/data/remote/service/chatwoot_client_service.dart';
import 'package:flutter/material.dart';

/// Handles interactions between chatwoot client api service[clientService] and
/// [localStorage] if persistence is enabled.
///
/// Results from repository operations are passed through [callbacks] to be handled
/// appropriately
abstract class ChatwootRepository{
  @protected final ChatwootClientService clientService;
  @protected final LocalStorage localStorage;
  @protected ChatwootCallbacks callbacks;
  List<StreamSubscription> _subscriptions = [];

  ChatwootRepository(
    this.clientService,
    this.localStorage,
    this.callbacks
  );

  Future<void> initialize(ChatwootUser? user);


  void getPersistedMessages();


  Future<void> getMessages();


  void listenForEvents();

  Future<void> sendMessage(ChatwootNewMessageRequest request);

  void sendAction(ChatwootActionType action);

  Future<void> clear();


  void dispose();

}


class ChatwootRepositoryImpl extends ChatwootRepository{

  bool _isListeningForEvents = false;

  ChatwootRepositoryImpl({
    required ChatwootClientService clientService,
    required LocalStorage localStorage,
    required ChatwootCallbacks streamCallbacks
  }):super(
      clientService,
      localStorage,
      streamCallbacks
  );


  /// Fetches persisted messages.
  ///
  /// Calls [callbacks.onMessagesRetrieved] when [clientService.getAllMessages] is successful
  /// Calls [callbacks.onError] when [clientService.getAllMessages] fails
  @override
  Future<void> getMessages() async{
    try{
      final messages = await clientService.getAllMessages();
      await localStorage.messagesDao.saveAllMessages(messages);
      callbacks.onMessagesRetrieved?.call(messages);
    }on ChatwootClientException catch(e){
      callbacks.onError?.call(e);
    }
  }


  /// Fetches persisted messages.
  ///
  /// Calls [callbacks.onPersistedMessagesRetrieved] if persisted messages are found
  @override
  void getPersistedMessages() {
    final persistedMessages = localStorage.messagesDao.getMessages();
    if(persistedMessages.isNotEmpty){
      callbacks.onPersistedMessagesRetrieved?.call(persistedMessages);
    }
  }

  /// Initializes client contact
  Future<void> initialize(ChatwootUser? user) async{

    try{
      if(user != null){
        await localStorage.userDao.saveUser(user);
      }

      //refresh contact
      final contact = await clientService.getContact();
      localStorage.contactDao.saveContact(contact);

      //refresh conversation
      final conversations = await clientService.getConversations();
      final persistedConversation = localStorage.conversationDao.getConversation()!;
      final refreshedConversation = conversations.firstWhere(
              (element) => element.id == persistedConversation.id,
          orElse: ()=>persistedConversation //highly unlikely orElse will be called but still added it just in case
      );
      localStorage.conversationDao.saveConversation(refreshedConversation);
    }on ChatwootClientException catch(e){
      callbacks.onError?.call(e);
    }


    listenForEvents();
  }


  ///Sends message to chatwoot inbox
  Future<void> sendMessage(ChatwootNewMessageRequest request) async{
    try{
      final createdMessage = await clientService.createMessage(request);
      await localStorage.messagesDao.saveMessage(createdMessage);
      callbacks.onMessageSent?.call(createdMessage, request.echoId);
      if(clientService.connection != null && !_isListeningForEvents){
        listenForEvents();
      }
    }on ChatwootClientException catch(e){
      callbacks.onError?.call(ChatwootClientException(e.cause, e.type, data: request.echoId));
    }
  }


  /// Connects to chatwoot websocket and starts listening for updates
  ///
  /// Calls [callbacks.onWelcome] when websocket welcome event is received
  /// Calls [callbacks.onPing] when websocket ping event is received
  /// Calls [callbacks.onConfirmedSubscription] when websocket subscription confirmation event is received
  /// Calls [callbacks.onMessageCreated] when websocket message created event is received, and
  /// message doesn't belong to current user
  /// Calls [callbacks.onMyMessageSent] when websocket message created event is received, and message belongs
  /// to current user
  @override
  void listenForEvents() {
    final token = localStorage.contactDao.getContact()?.pubsubToken;
    if(token == null){
      return;
    }
    clientService.startWebSocketConnection(localStorage.contactDao.getContact()!.pubsubToken);

    final newSubscription = clientService.connection!.stream.listen((event) {

      ChatwootEvent chatwootEvent = ChatwootEvent.fromJson(jsonDecode(event));
      if(chatwootEvent.type == ChatwootEventType.welcome){
        callbacks.onWelcome?.call();
      }else if(chatwootEvent.type == ChatwootEventType.ping){
        callbacks.onPing?.call();
      }else if(chatwootEvent.type == ChatwootEventType.confirm_subscription){
        if(!_isListeningForEvents){
          _isListeningForEvents = true;
        }
        callbacks.onConfirmedSubscription?.call();
      }else if(chatwootEvent.message?.event == ChatwootEventMessageType.message_created){
        print("here comes message: $event");
        final message = chatwootEvent.message!.data!.getMessage();
        localStorage.messagesDao.saveMessage(message);
        if(message.isMine){
          callbacks.onMessageDelivered?.call(message, chatwootEvent.message!.data!.echoId!);
        }else{
          callbacks.onMessageReceived?.call(message);
        }
      }else if(chatwootEvent.message?.event == ChatwootEventMessageType.conversation_typing_off){
        callbacks.onConversationStoppedTyping?.call();
      }else if(chatwootEvent.message?.event == ChatwootEventMessageType.conversation_typing_on){
        callbacks.onConversationStartedTyping?.call();
      }else if(chatwootEvent.message?.event == ChatwootEventMessageType.presence_update){
        final presenceStatuses = (chatwootEvent.message!.data!.users as Map<dynamic, dynamic>).values;
        final isOnline = presenceStatuses.contains("online");
        if(isOnline){
          callbacks.onConversationIsOnline?.call();
        }else{
          callbacks.onConversationIsOffline?.call();
        }
      }else{
        print("chatwoot unknown event: $event");
      }
    });
    _subscriptions.add(newSubscription);
  }

  /// Clears all data related to current chatwoot client instance
  @override
  Future<void> clear() async {
    await localStorage.clear();
  }

  /// Cancels websocket stream subscriptions and disposes [localStorage]
  @override
  void dispose() {
    localStorage.dispose();
    callbacks = ChatwootCallbacks();
    _subscriptions.forEach((subs) { subs.cancel();});
  }

  ///Send actions like user started typing
  @override
  void sendAction(ChatwootActionType action) {
    clientService.sendAction(localStorage.contactDao.getContact()!.pubsubToken, action);
  }

}