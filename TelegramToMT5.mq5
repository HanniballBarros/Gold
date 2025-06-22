//+------------------------------------------------------------------+
//|                   TelegramToMT5.mq5                              |
//|     Receives signals from Telegram, places and manages orders    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, HanniballBarros"
#property version   "2.0"
#property strict

#include <Trade\Trade.mqh>
#include <Telegram.mqh>
#include <Common.mqh>      // For any extra helpers you might use
#include <jason.mqh>       // For JSON parsing if used in Telegram.mqh


// ====== USER CONFIGURATION ======
input string   TelegramBotToken = "7743155685:AAGtE2aJDITlMupH7Afxm-sNyJhPAMzkleU"; // <- paste your bot token here
input string   SignalGroup      = "@goldsnipers11";   // <- Telegram group username or chat_id as string
input double   RiskPercent      = 2.5;                // Risk per signal (% of balance)
input double   RiskSplit1       = 0.5;                // 50% for TP1
input double   RiskSplit2       = 0.3;                // 30% for TP2
input double   RiskSplit3       = 0.2;                // 20% for TP3
input int      UpdateInterval   = 1;                  // Check for updates every X seconds

CTrade trade;
class CTradingBot : public CCustomBot { public: void ProcessMessages(void) { } };
CTradingBot* g_bot = NULL;

string Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }

struct SignalData {
   string symbol;
   string direction;
   double entryLow, entryHigh, sl, tp[3];
   long   chat_id;
   int    message_id;
   bool   valid;
};
struct ManagedSignal {
   SignalData signal;
   ulong      order[3];
   ulong      position[3];
   double     lots[3];
   double     entry_price;
   bool       tp_hit[3];
   bool       active;
};
ManagedSignal active_signal;
double bankroll = 0;

int OnInit() {
   bankroll = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!InitializeTelegramBot()) return INIT_FAILED;
   if(!EventSetTimer(UpdateInterval)) return INIT_FAILED;
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) {
   EventKillTimer();
   if(g_bot!=NULL) { delete g_bot; g_bot=NULL; }
   Comment("");
}
void OnTimer() {
   CheckNewMessages();
   if(active_signal.active) {
      string status = "Signal: "+active_signal.signal.symbol+" "+active_signal.signal.direction+"\n";
      for(int i=0;i<3;i++)
         status += StringFormat("Order %d: pending=%s, pos=%s, TP hit=%s\n",i+1,
            (active_signal.order[i]>0?"YES":"NO"),
            (active_signal.position[i]>0?"YES":"NO"),
            (active_signal.tp_hit[i]?"YES":"NO"));
      Comment(status);
   } else {
      Comment("No active signal");
   }
}
bool InitializeTelegramBot() {
   if(StringLen(TelegramBotToken)==0) { Print("Bot token not set!"); return false; }
   g_bot = new CTradingBot();
   if(g_bot==NULL) return false;
   if(g_bot.Token(TelegramBotToken)!=0) { delete g_bot; g_bot=NULL; return false; }
   if(g_bot.GetMe()!=0) { delete g_bot; g_bot=NULL; return false; }
   return true;
}
void CheckNewMessages() {
   if(g_bot==NULL) return;
   if(g_bot.GetUpdates()!=0) return;

   for(int i=0; i<g_bot.ChatsTotal(); i++) {
      CCustomChat *chat = g_bot.GetChatByIndex(i);
      if(chat==NULL) continue;
      if(!IsGroupMatch(chat)) continue;
      string msg = chat.m_new_one.message_text;
      SignalData signal = ParseSignal(msg, chat.m_new_one.chat_id, chat.m_new_one.message_id);
      if(signal.valid && (!active_signal.active || signal.message_id!=active_signal.signal.message_id)) {
         bankroll = AccountInfoDouble(ACCOUNT_BALANCE);
         PlaceSignalOrders(signal);
         break;
      }
   }
}
bool IsGroupMatch(CCustomChat *chat) {
   if(StringLen(SignalGroup) && chat.m_new_one.chat_username==SignalGroup) return true;
   if(IntegerToString(chat.m_new_one.chat_id)==SignalGroup) return true;
   return false;
}
SignalData ParseSignal(const string &txt, long chat_id, int msg_id) {
   SignalData sdata;
   sdata.symbol = "XAUUSD"; sdata.direction = "";
   sdata.entryLow = 0; sdata.entryHigh=0; sdata.sl=0; ArrayInitialize(sdata.tp,0);
   sdata.chat_id = chat_id; sdata.message_id = msg_id; sdata.valid = false;

   string text = txt, lines[];
   StringReplace(text,"\r",""); StringReplace(text,"\n\n","\n");
   int n = StringSplit(text, '\n', lines); if(n<5) return sdata;

   string header[]; int nh = StringSplit(lines[0],' ',header);
   if(nh<2) return sdata;
   string dir = Trim(header[1]);
   StringToUpper(dir);
   sdata.symbol    = Trim(header[0]);
   sdata.direction = dir;

   for(int i=1; i<n; i++) {
      string l = Trim(lines[i]);
      if(StringFind(l,"ENTRY")==0) {
         string vals[]; int ne = StringSplit(l,' ',vals);
         if(ne==3) {
            string range[]; int nr=StringSplit(vals[2],'-',range);
            if(nr==2) { sdata.entryLow=StringToDouble(range[0]); sdata.entryHigh=StringToDouble(range[1]); }
            else { sdata.entryLow=StringToDouble(vals[2]); sdata.entryHigh=sdata.entryLow; }
         }
      }
      if(StringFind(l,"SL")==0) {
         string vals[]; int ns=StringSplit(l,' ',vals);
         if(ns==2) sdata.sl=StringToDouble(vals[1]);
      }
      if(StringFind(l,"TP")==0) {
         string vals[]; int ntp=StringSplit(l,' ',vals);
         if(ntp==2) { for(int j=0;j<3;j++) if(sdata.tp[j]==0) { sdata.tp[j]=StringToDouble(vals[1]); break; } }
      }
   }
   if((sdata.direction=="SELL"||sdata.direction=="BUY") && sdata.entryLow>0 && sdata.sl>0 && sdata.tp[0]>0)
      sdata.valid=true;
   return sdata;
}
void PlaceSignalOrders(SignalData &signal) {
   ArrayInitialize(active_signal.order,0); ArrayInitialize(active_signal.position,0);
   ArrayInitialize(active_signal.tp_hit,false);
   active_signal.signal = signal; active_signal.active = true;
   active_signal.entry_price = (signal.entryLow+signal.entryHigh)/2.0;

   double risk = bankroll*(RiskPercent/100.0);
   double lots[3]; lots[0]=risk*RiskSplit1; lots[1]=risk*RiskSplit2; lots[2]=risk*RiskSplit3;
   for(int i=0;i<3;i++)
      active_signal.lots[i] = CalculateLots(signal.symbol, lots[i], active_signal.entry_price, signal.sl, signal.direction);

   double entry = active_signal.entry_price;
   double last_ask = SymbolInfoDouble(signal.symbol, SYMBOL_ASK), last_bid = SymbolInfoDouble(signal.symbol, SYMBOL_BID);

   for(int i=0;i<3;i++) {
      ENUM_ORDER_TYPE order_type;
      if(signal.direction=="BUY") {
         order_type = (entry < last_ask) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP;
      } else {
         order_type = (entry > last_bid) ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP;
      }
      ulong ticket = PlacePending(signal.symbol, order_type, active_signal.lots[i], entry, signal.sl, signal.tp[i], 12345+i);
      active_signal.order[i]=ticket;
   }
}
ulong PlacePending(string symbol, ENUM_ORDER_TYPE order_type, double lot, double price, double sl, double tp, int magic) {
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_PENDING; req.symbol=symbol; req.volume=lot; req.price=price; req.sl=sl; req.tp=tp; req.deviation=20;
   req.magic=magic; req.type=order_type; req.type_filling=ORDER_FILLING_RETURN; req.type_time=ORDER_TIME_GTC;
   if(OrderSend(req,res) && (res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED)) return res.order;
   Print("Failed to place order: ",res.comment); return 0;
}
double CalculateLots(string symbol, double risk_amount, double entry, double sl, string direction) {
   double contract_size = SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE), point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   double stop_loss=MathAbs(entry-sl); if(stop_loss<point) stop_loss=point*10;
   double lot = risk_amount/(stop_loss*contract_size/point); lot=NormalizeDouble(lot,2);
   if(lot<SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN)) lot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   return lot;
}
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result) {
   if(!active_signal.active) return;

   if(trans.type==TRADE_TRANSACTION_DEAL_ADD) {
      for(int i=0;i<3;i++) {
         if(active_signal.order[i]>0 && (trans.order==active_signal.order[i] || trans.position==active_signal.position[i] || trans.position==0)) {
            for(int j=0;j<PositionsTotal();j++) {
               ulong pos_ticket=PositionGetTicket(j);
               if(PositionGetInteger(POSITION_MAGIC)==12345+i && PositionGetString(POSITION_SYMBOL)==active_signal.signal.symbol &&
                  MathAbs(PositionGetDouble(POSITION_VOLUME)-active_signal.lots[i])<0.00001) {
                  active_signal.position[i]=pos_ticket; active_signal.order[i]=0; break;
               }
            }
         }
      }
   }
   for(int i=0;i<3;i++) {
      ulong pos_ticket=active_signal.position[i]; if(pos_ticket==0) continue;
      if(!PositionSelectByTicket(pos_ticket)) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      double last_bid=SymbolInfoDouble(symbol,SYMBOL_BID), last_ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
      bool is_buy = (active_signal.signal.direction=="BUY");
      double tp1=active_signal.signal.tp[0], tp2=active_signal.signal.tp[1], entry=active_signal.entry_price;

      if(!active_signal.tp_hit[0] && ((is_buy && last_bid>=tp1) || (!is_buy && last_ask<=tp1))) {
         active_signal.tp_hit[0]=true;
         for(int j=1;j<3;j++)
            if(active_signal.position[j]>0 && PositionSelectByTicket(active_signal.position[j]))
               trade.PositionModify(symbol,entry,PositionGetDouble(POSITION_TP));
      }
      if(!active_signal.tp_hit[1] && ((is_buy && last_bid>=tp2) || (!is_buy && last_ask<=tp2))) {
         active_signal.tp_hit[1]=true;
         if(active_signal.position[2]>0 && PositionSelectByTicket(active_signal.position[2]))
            trade.PositionModify(symbol,tp1,PositionGetDouble(POSITION_TP));
      }
   }
   int open=0; for(int i=0;i<3;i++) if(active_signal.position[i]>0 && PositionSelectByTicket(active_signal.position[i])) open++;
   if(open==0) active_signal.active=false;
}
