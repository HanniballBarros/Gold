//+------------------------------------------------------------------+
//|                                              TelegramSignalEA.mq5|
//|         Custom: XAUUSD Signal Parser + Multi-Order Execution     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, HanniballBarros"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Telegram.mqh>

// Adjust these for your use
input string   TelegramBotToken = "<YOUR_BOT_TOKEN>"; // <- paste your bot token here
input string   SignalGroup      = "@YourGroupName";   // <- Telegram group username (or use chat_id)
input double   RiskPercent      = 2.5;                // Risk per signal (% of balance)
input double   RiskSplit1       = 0.5;                // 50% for TP1
input double   RiskSplit2       = 0.3;                // 30% for TP2
input double   RiskSplit3       = 0.2;                // 20% for TP3
input int      UpdateInterval   = 1;                  // Check for updates every X seconds

CTrade         trade;
CTradingBot   *g_bot = NULL;

// Structure to hold parsed signal
struct SignalData {
   string symbol;
   string direction; // "BUY" or "SELL"
   double entryLow;
   double entryHigh;
   double sl;
   double tp[3];
   ulong  chat_id;
   int    message_id;
   bool   valid;
};

// Structure to track active signal/orders
struct ManagedSignal {
   SignalData signal;
   ulong      ticket[3];
   double     lots[3];
   double     open_price[3];
   bool       tp_hit[3];
   bool       active;
};

ManagedSignal active_signal;
double bankroll = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   bankroll = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!InitializeTelegramBot()) {
      Print("Failed to initialize Telegram bot. Please check your bot token.");
      return INIT_FAILED;
   }
   if(!EventSetTimer(UpdateInterval)) {
      Print("Failed to set timer!");
      return INIT_FAILED;
   }
   Print("Telegram Signal EA initialized successfully");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   if(g_bot != NULL) { delete g_bot; g_bot = NULL; }
   Comment("");
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
   CheckNewMessages();
   ManageActiveSignal();
}

//+------------------------------------------------------------------+
//| Initialize Telegram Bot                                          |
//+------------------------------------------------------------------+
bool InitializeTelegramBot() {
   if(StringLen(TelegramBotToken) == 0) {
      Print("Error: Telegram Bot Token is not set!");
      return false;
   }
   g_bot = new CTradingBot();
   if(g_bot == NULL) { Print("Failed to create bot instance"); return false; }
   int res = g_bot.Token(TelegramBotToken);
   if(res != 0) { Print("Failed to set bot token. Error code: ", res); delete g_bot; g_bot = NULL; return false; }
   res = g_bot.GetMe();
   if(res != 0) { Print("Failed to connect to Telegram API. Error code: ", res); delete g_bot; g_bot = NULL; return false; }
   Print("Bot name: ", g_bot.Name());
   Print("Bot token: ", TelegramBotToken);
   Print("Connection test successful");
   return true;
}

//+------------------------------------------------------------------+
//| Check for new messages in the channel                            |
//+------------------------------------------------------------------+
void CheckNewMessages() {
   if(g_bot == NULL) return;
   int res = g_bot.GetUpdates();
   if(res != 0) return;

   // Process only the latest signal from the chosen group
   for(int i = 0; i < g_bot.ChatsTotal(); i++) {
      CCustomChat *chat = g_bot.m_chats.GetNodeAtIndex(i);
      if(chat == NULL) continue;
      if(!IsGroupMatch(chat)) continue;

      string msg = chat.m_new_one.message_text;
      SignalData signal = ParseSignal(msg, chat.m_new_one.chat_id, chat.m_new_one.message_id);
      if(signal.valid && (active_signal.active == false || signal.message_id != active_signal.signal.message_id)) {
         Print("New valid trading signal detected.");
         bankroll = AccountInfoDouble(ACCOUNT_BALANCE);
         PlaceSignalOrders(signal);
         break; // Only process one signal per tick
      }
   }
}

//+------------------------------------------------------------------+
//| Group filter: Only accept from your group                        |
//+------------------------------------------------------------------+
bool IsGroupMatch(CCustomChat *chat) {
   // Match by group username or chat_id
   if(StringLen(SignalGroup) && chat.m_new_one.chat_username == SignalGroup) return true;
   if(chat.m_new_one.chat_id == StrToInteger(SignalGroup)) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Parse signal from message text                                   |
//+------------------------------------------------------------------+
SignalData ParseSignal(const string &txt, ulong chat_id, int msg_id) {
   SignalData sdata;
   sdata.symbol = "XAUUSD";
   sdata.direction = "";
   sdata.entryLow = 0;
   sdata.entryHigh = 0;
   sdata.sl = 0;
   ArrayInitialize(sdata.tp, 0);
   sdata.chat_id = chat_id;
   sdata.message_id = msg_id;
   sdata.valid = false;

   string text = txt;
   StringReplace(text, "\r", "");
   StringReplace(text, "\n\n", "\n");
   string lines[];
   int n = StringSplit(text, '\n', lines);
   if(n < 5) return sdata;

   // 1st line: e.g. XAUUSD SELL
   string header[];
   int nh = StringSplit(lines[0], ' ', header);
   if(nh < 2) return sdata;
   sdata.symbol = StringTrim(header[0]);
   sdata.direction = StringTrim(header[1]);

   // Find ENTRY, SL, TPs
   for(int i=1; i<n; i++) {
      string l = StringTrim(lines[i]);
      if(StringFind(l, "ENTRY") == 0) {
         string vals[];
         int ne = StringSplit(l, ' ', vals);
         if(ne == 3) {
            string range[];
            int nr = StringSplit(vals[2], '-', range);
            if(nr == 2) {
               sdata.entryLow = StrToDouble(range[0]);
               sdata.entryHigh = StrToDouble(range[1]);
            } else {
               sdata.entryLow = StrToDouble(vals[2]);
               sdata.entryHigh = sdata.entryLow;
            }
         }
      }
      if(StringFind(l, "SL") == 0) {
         string vals[];
         int ns = StringSplit(l, ' ', vals);
         if(ns == 2) sdata.sl = StrToDouble(vals[1]);
      }
      if(StringFind(l, "TP") == 0) {
         string vals[];
         int ntp = StringSplit(l, ' ', vals);
         if(ntp == 2) {
            for(int j=0;j<3;j++) {
               if(sdata.tp[j] == 0) { sdata.tp[j] = StrToDouble(vals[1]); break; }
            }
         }
      }
   }
   // Validation
   if((sdata.direction == "SELL" || sdata.direction == "BUY") &&
      sdata.entryLow > 0 && sdata.sl > 0 && sdata.tp[0] > 0) {
      sdata.valid = true;
   }
   return sdata;
}

//+------------------------------------------------------------------+
//| Place three orders for the parsed signal                         |
//+------------------------------------------------------------------+
void PlaceSignalOrders(SignalData &signal) {
   double risk = bankroll * (RiskPercent/100.0);
   double risk1 = risk * RiskSplit1;
   double risk2 = risk * RiskSplit2;
   double risk3 = risk * RiskSplit3;

   double entry = (signal.entryLow + signal.entryHigh) / 2.0;
   ENUM_ORDER_TYPE order_type = (signal.direction == "SELL") ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   // Calculate lot sizes for each order (simple method, you may want to use more advanced logic)
   double lot1 = CalculateLots(signal.symbol, risk1, entry, signal.sl, order_type);
   double lot2 = CalculateLots(signal.symbol, risk2, entry, signal.sl, order_type);
   double lot3 = CalculateLots(signal.symbol, risk3, entry, signal.sl, order_type);

   ulong tickets[3] = {0,0,0};
   double open_prices[3] = {0,0,0};

   // Place three market orders
   double price = SymbolInfoDouble(signal.symbol, (order_type == ORDER_TYPE_BUY) ? SYMBOL_ASK : SYMBOL_BID);
   double sl = signal.sl, tp1 = signal.tp[0], tp2 = signal.tp[1], tp3 = signal.tp[2];

   // Order 1 (for TP1)
   if(trade.PositionOpen(signal.symbol, order_type, lot1, price, sl, tp1, "Signal TP1")) {
      tickets[0] = trade.ResultOrder();
      open_prices[0] =*

