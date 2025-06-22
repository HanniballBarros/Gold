//+------------------------------------------------------------------+
//|                                              TelegramSignalEA.mq5 |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Salman Soltaniyan"
#property link      "https://www.mql5.com/en/users/salmansoltaniyan"
#property description "Telegram Signal EA for MetaTrader 5, You can post a job for me: https://www.mql5.com/en/job/new?prefered=salmansoltaniyan"
#property version   "1.00"
#property strict

// Description: Telegram Signal EA for MetaTrader 5
// Author: Salman Soltaniyan
// You can post a job for me: https://www.mql5.com/en/job/new?prefered=salmansoltaniyan

#include <Telegram.mqh>

// Custom bot class to access protected members
class CTradingBot : public CCustomBot
  {
public:
   // Override ProcessMessages to handle new messages
   virtual void      ProcessMessages(void)
     {
      string commentText = "Processing messages... Total chats: " + IntegerToString(ChatsTotal()) + "\n\n";

      // Process new messages
      for(int i = 0; i < ChatsTotal(); i++)
        {
         CCustomChat* chat = m_chats.GetNodeAtIndex(i);
         if(chat == NULL)
           {
            commentText += "Chat " + IntegerToString(i) + " is NULL\n\n";
            continue;
           }

         commentText += "Checking chat " + IntegerToString(i) + ":\n";
         commentText += "  - Chat type: " + chat.m_new_one.chat_type + "\n";
         
         string messageText = "";
         if(chat.m_new_one.is_channel_post)
           {
            commentText += "  - Channel name: " + chat.m_new_one.chat_first_name + "\n";
            commentText += "  - Channel ID: " + IntegerToString(chat.m_new_one.chat_id) + "\n";
            commentText += "  - Channel username: @" + chat.m_new_one.chat_username + "\n";
            commentText += "  - Channel post ID: " + IntegerToString(chat.m_new_one.channel_post_id) + "\n";
            commentText += "  - Channel post text: " + chat.m_new_one.channel_post_text + "\n";
            messageText = chat.m_new_one.channel_post_text;
           }
         else
           {
            // Display chat/group information
            if(chat.m_new_one.chat_type == "group" || chat.m_new_one.chat_type == "supergroup")
              {
               commentText += "  - Group name: " + chat.m_new_one.chat_first_name + "\n";
               commentText += "  - Group ID: " + IntegerToString(chat.m_new_one.chat_id) + "\n";
               if(StringLen(chat.m_new_one.chat_username) > 0)
                  commentText += "  - Group username: @" + chat.m_new_one.chat_username + "\n";
              }
            else
              {
               commentText += "  - Chat name: " + chat.m_new_one.chat_first_name + "\n";
               if(StringLen(chat.m_new_one.chat_username) > 0)
                  commentText += "  - Chat username: @" + chat.m_new_one.chat_username + "\n";
              }
            
            // Display sender information
            commentText += "  - Sender name: " + chat.m_new_one.from_first_name + " " + chat.m_new_one.from_last_name + "\n";
            if(StringLen(chat.m_new_one.from_username) > 0)
               commentText += "  - Sender username: @" + chat.m_new_one.from_username + "\n";
            
            commentText += "  - Message ID: " + IntegerToString(chat.m_new_one.message_id) + "\n";
            commentText += "  - Message text: " + chat.m_new_one.message_text + "\n";
            messageText = chat.m_new_one.message_text;
           }

         // Add extra blank line between different chats
         commentText += "\n";
        }
        
        Comment(commentText);
     }

 
  };

// Input parameters
input string   TelegramBotToken = "";  // Your Telegram Bot Token
input int      UpdateInterval = 1;     // Check for updates every X seconds

// Global variables
CTradingBot* g_bot = NULL;  // Telegram bot instance

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
// Initialize Telegram bot
   if(!InitializeTelegramBot())
     {
      Print("Failed to initialize Telegram bot. Please check your bot token.");
      return INIT_FAILED;
     }

// Set timer for checking messages
   if(!EventSetTimer(UpdateInterval))
     {
      Print("Failed to set timer!");
      return INIT_FAILED;
     }

   Print("Telegram Signal EA initialized successfully");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
// Remove timer
   EventKillTimer();

   if(g_bot != NULL)
     {
      delete g_bot;
      g_bot = NULL;
     }
     
   // Clear any previous comments
   Comment("");
  }

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
   CheckNewMessages();
  }

//+------------------------------------------------------------------+
//| Initialize Telegram Bot                                          |
//+------------------------------------------------------------------+
bool InitializeTelegramBot()
  {
   if(StringLen(TelegramBotToken) == 0)
     {
      Print("Error: Telegram Bot Token is not set!");
      return false;
     }

// Create bot instance
   g_bot = new CTradingBot();
   if(g_bot == NULL)
     {
      Print("Failed to create bot instance");
      return false;
     }

// Set bot token
   int res = g_bot.Token(TelegramBotToken);
   if(res != 0)
     {
      Print("Failed to set bot token. Error code: ", res);
      delete g_bot;
      g_bot = NULL;
      return false;
     }

// Test connection by getting bot info
   res = g_bot.GetMe();
   if(res != 0)
     {
      Print("Failed to connect to Telegram API. Error code: ", res);
      delete g_bot;
      g_bot = NULL;
      return false;
     }

   Print("Bot name: ", g_bot.Name());
   Print("Bot token: ", TelegramBotToken);
   Print("Connection test successful");

   return true;
  }

//+------------------------------------------------------------------+
//| Check for new messages in the channel                            |
//+------------------------------------------------------------------+
void CheckNewMessages()
  {
   if(g_bot == NULL)
      return;

   string commentText = "Checking for new messages...\n";

// Get updates from Telegram
   int res = g_bot.GetUpdates();
   if(res == 0)
     {
      commentText += "Successfully got updates from Telegram\n";
      commentText += "Total chats: " + IntegerToString(g_bot.ChatsTotal()) + "\n";
      Comment(commentText);

      // Process messages using the overridden method
      g_bot.ProcessMessages();
     }
   else
     {
      commentText += "Failed to get updates. Error code: " + IntegerToString(res) + "\n";
      commentText += "Error description: " + IntegerToString(GetLastError());
      Comment(commentText);
     }
  } 
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| MIT License                                                       |
//|                                                                  |
//| Copyright (c) 2024 Salman Soltaniyan                             |
//|                                                                  |
//| Permission is hereby granted, free of charge, to any person      |
//| obtaining a copy of this software and associated documentation   |
//| files (the "Software"), to deal in the Software without          |
//| restriction, including without limitation the rights to use,     |
//| copy, modify, merge, publish, distribute, sublicense, and/or     |
//| sell copies of the Software, and to permit persons to whom the   |
//| Software is furnished to do so, subject to the following         |
//| conditions:                                                      |
//|                                                                  |
//| The above copyright notice and this permission notice shall be   |
//| included in all copies or substantial portions of the Software.  |
//|                                                                  |
//| THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,  |
//| EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES  |
//| OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND         |
//| NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT      |
//| HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,     |
//| WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING     |
//| FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR    |
//| OTHER DEALINGS IN THE SOFTWARE.                                  |
//+------------------------------------------------------------------+
