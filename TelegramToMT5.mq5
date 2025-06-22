//+------------------------------------------------------------------+
//|                   TelegramToMT5.mq5                              |
//|     Receives signals from Telegram, places and manages orders    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, HanniballBarros"
#property version   "2.0"
#property strict

#include <Trade\Trade.mqh>
#include <Telegram.mqh>

// ====== USER CONFIGURATION ======
input string   TelegramBotToken = "<YOUR_BOT_TOKEN>"; // <- paste your bot token here
input string   SignalGroup      = "@YourGroupName";   // <- Telegram group username or chat_id as string
input double   RiskPercent      = 2.5;                // Risk per signal (% of balance)
input double   RiskSplit1       = 0.5;                // 50% for TP1
input double   RiskSplit2       = 0.3;                // 30% for TP2
input double   RiskSplit3       = 0.2;                // 20% for TP3
input int      UpdateInterval   = 1;                  // Check for updates every X seconds

CTrade trade;
CTradingBot *g_bot = NULL;

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

struct ManagedSignal {
   SignalData signal;
   ulong      order[3];      // Pending order tickets
   ulong      position[3];   // Opened position tickets
   double     lots[3];
   double     entry_price;
   bool       tp_hit[3];
   bool       active;
   bool       pending_executed[3];
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
   // Comment active signal status for monitoring
   if(active_signal.active) {
      string status = "Signal: " + active_signal.signal.symbol + " " + active_signal.signal.direction + "\n";
      for(int i=0;i<3;i++) {
         status += StringFormat("Order %d: pending=%s, pos=%s, TP hit=%s\n", i+1,
            (active_signal.order[i]>0?"YES":"NO"),
            (active_signal.position[i]>0?"YES":"NO"),
            (active_signal.tp_hit[i]?"YES":"NO"));
      }
      Comment(status);
   } else {
      Comment("No active signal");
   }
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

   string header[];
   int nh = StringSplit(lines[0], ' ', header);
   if(nh < 2) return sdata;
   sdata.symbol = StringTrim(header[0]);
   sdata.direction = StringTrim(header[1]);

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
   if((sdata.direction == "SELL" || sdata.direction == "BUY") &&
      sdata.entryLow > 0 && sdata.sl > 0 && sdata.tp[0] > 0) {
      sdata.valid = true;
   }
   return sdata;
}

//+------------------------------------------------------------------+
//| Place three pending orders for the parsed signal                 |
//+------------------------------------------------------------------+
void PlaceSignalOrders(SignalData &signal) {
   ArrayInitialize(active_signal.order, 0);
   ArrayInitialize(active_signal.position, 0);
   ArrayInitialize(active_signal.tp_hit, false);
   ArrayInitialize(active_signal.pending_executed, false);
   active_signal.signal = signal;
   active_signal.active = true;
   active_signal.entry_price = (signal.entryLow + signal.entryHigh) / 2.0;

   double risk = bankroll * (RiskPercent/100.0);
   double risk1 = risk * RiskSplit1;
   double risk2 = risk * RiskSplit2;
   double risk3 = risk * RiskSplit3;

   double entry = active_signal.entry_price;
   ENUM_ORDER_TYPE order_type;
   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_RETURN;
   int magic = 12345;

   double lot1 = CalculateLots(signal.symbol, risk1, entry, signal.sl, signal.direction);
   double lot2 = CalculateLots(signal.symbol, risk2, entry, signal.sl, signal.direction);
   double lot3 = CalculateLots(signal.symbol, risk3, entry, signal.sl, signal.direction);
   active_signal.lots[0]=lot1; active_signal.lots[1]=lot2; active_signal.lots[2]=lot3;

   double last_ask = SymbolInfoDouble(signal.symbol, SYMBOL_ASK);
   double last_bid = SymbolInfoDouble(signal.symbol, SYMBOL_BID);

   ENUM_ORDER_TYPE pending_types[3];
   for(int i=0;i<3;i++) {
      // TP1, TP2, TP3
      double tp = signal.tp[i];
      ulong ticket = 0;
      if(signal.direction == "BUY") {
         if(entry < last_ask)
            order_type = ORDER_TYPE_BUY_LIMIT;
         else
            order_type = ORDER_TYPE_BUY_STOP;
         ticket = PlacePending(signal.symbol, order_type, active_signal.lots[i], entry, signal.sl, tp, magic+i);
      } else {
         if(entry > last_bid)
            order_type = ORDER_TYPE_SELL_LIMIT;
         else
            order_type = ORDER_TYPE_SELL_STOP;
         ticket = PlacePending(signal.symbol, order_type, active_signal.lots[i], entry, signal.sl, tp, magic+i);
      }
      active_signal.order[i] = ticket;
      pending_types[i] = order_type;
   }
   Print("Three pending orders placed for signal: ", signal.symbol, " ", signal.direction);
}

//+------------------------------------------------------------------+
//| Place a pending order and return its ticket                      |
//+------------------------------------------------------------------+
ulong PlacePending(string symbol, ENUM_ORDER_TYPE order_type, double lot, double price, double sl, double tp, int magic) {
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_PENDING;
   req.symbol = symbol;
   req.volume = lot;
   req.price = price;
   req.sl = sl;
   req.tp = tp;
   req.deviation = 20;
   req.magic = magic;
   req.type = order_type;
   req.type_filling = ORDER_FILLING_RETURN;
   req.type_time = ORDER_TIME_GTC;
   OrderSend(req,res);
   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
      return res.order;
   else
      Print("Failed to place order: ", res.comment);
   return 0;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLots(string symbol, double risk_amount, double entry, double sl, string direction) {
   double contract_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double stop_loss = MathAbs(entry - sl);
   if(stop_loss < point) stop_loss = point * 10;
   double lot = risk_amount / (stop_loss * contract_size / point);
   lot = NormalizeDouble(lot, 2);
   if(lot < SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN)) lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   return lot;
}

//+------------------------------------------------------------------+
//| Event handler: trade/order/position events                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result) {
   // Track when pending orders become positions
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD && trans.order_type > 2 && active_signal.active) {
      // Pending order placed, nothing to do
   }
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && active_signal.active) {
      // Pending executed? See if a new position is opened from our order
      for(int i=0;i<3;i++) {
         if(active_signal.order[i] > 0 &&
            (trans.order == active_signal.order[i] || trans.position == active_signal.position[i] || trans.position == 0)
         ) {
            // Find open position from this order
            for(int j=0;j<PositionsTotal();j++) {
               ulong pos_ticket = PositionGetTicket(j);
               if(PositionGetInteger(POSITION_MAGIC) == 12345+i &&
                  PositionGetString(POSITION_SYMBOL) == active_signal.signal.symbol &&
                  MathAbs(PositionGetDouble(POSITION_VOLUME) - active_signal.lots[i]) < 0.00001) {
                  active_signal.position[i] = pos_ticket;
                  active_signal.order[i] = 0; // clear pending
                  break;
               }
            }
         }
      }
   }
   // Trailing & move SL logic: when TP1/TP2 hit, update other SLs
   for(int i=0;i<3;i++) {
      ulong pos_ticket = active_signal.position[i];
      if(pos_ticket == 0) continue;
      if(!PositionSelectByTicket(pos_ticket)) continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      double pos_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double pos_tp    = PositionGetDouble(POSITION_TP);
      double pos_sl    = PositionGetDouble(POSITION_SL);
      double last_bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double last_ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

      bool is_buy = (active_signal.signal.direction == "BUY");
      double tp1 = active_signal.signal.tp[0];
      double tp2 = active_signal.signal.tp[1];
      double entry = active_signal.entry_price;

      // Check for TP1 hit
      if(!active_signal.tp_hit[0] && ((is_buy && last_bid >= tp1) || (!is_buy && last_ask <= tp1))) {
         active_signal.tp_hit[0] = true;
         // Move SL for 2 and 3 to entry
         for(int j=1;j<3;j++) {
            if(active_signal.position[j] > 0 && PositionSelectByTicket(active_signal.position[j])) {
               trade.PositionModify(symbol, entry, PositionGetDouble(POSITION_TP));
               Print("TP1 hit, moved SL for order ", j+1, " to entry");
            }
         }
      }
      // Check for TP2 hit
      if(!active_signal.tp_hit[1] && ((is_buy && last_bid >= tp2) || (!is_buy && last_ask <= tp2))) {
         active_signal.tp_hit[1] = true;
         // Move SL for order 3 to TP1
         if(active_signal.position[2] > 0 && PositionSelectByTicket(active_signal.position[2])) {
            trade.PositionModify(symbol, tp1, PositionGetDouble(POSITION_TP));
            Print("TP2 hit, moved SL for last order to TP1");
         }
      }
   }
   // Deactivate signal if all positions closed
   int open = 0;
   for(int i=0;i<3;i++) if(active_signal.position[i]>0 && PositionSelectByTicket(active_signal.position[i])) open++;
   if(open == 0) active_signal.active = false;
}

//+------------------------------------------------------------------+
//| Custom CTradingBot inherits from CCustomBot                      |
//+------------------------------------------------------------------+
class CTradingBot : public CCustomBot {
public:
   virtual void ProcessMessages(void) {
      // Overridden, logic handled in EA for now
   }
};
//+------------------------------------------------------------------+
