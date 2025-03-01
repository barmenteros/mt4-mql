/**
 * Duel: A bi-directional grid with adjustable pyramiding, martingale or reverse-martingale position sizing.
 *
 *  Eye to eye stand winners and losers
 *  Hurt by envy, cut by greed
 *  Face to face with their own disillusions
 *  The scars of old romances still on their cheeks
 *
 *  The first cut won't hurt at all
 *  The second only makes you wonder
 *  The third will have you on your knees
 *
 *
 * Input parameters:
 * -----------------
 * � Sequence.ID:  Every new sequence gets a unique instance id assigned which - beneath others - affects magic order number
 *    generation. This way multiple grids (EA instances) can run in parallel even on the same symbol. Each instance logs its
 *    activities to a logfile named "{symbol}.Duel.{instance-id}.log") and writes status changes to a status file named
 *    "{symbol}.Duel.{instance-id}.set". In both cases the sequence id is part of the file name. A sequence can be reloaded
 *    and fully restored from a status file. This enables the user to unload the EA on one machine (e.g. a laptop), move the
 *    file to another machine (e.g. a VPS or server) and to continue the sequence there by pointing the EA to the moved
 *    status file. To do this the user enters the sequence id of the status file in the input field "Sequence.ID". For new
 *    sequences the input field stays empty and sequence id and magic numbers are auto-generated.
 *
 * � GridDirection:  The EA supports two different grid modes. In unidirectional mode (input "long" or "short") it creates a
 *    grid for a single trade direction. In birectional mode (input "both") it creates a separate grid for each direction.
 *    A "long" grid consists of BuyStop and/or BuyLimit orders, a "short" grid of SellStop and/or SellLimit orders.
 *
 * � GridVolatility:
 *
 *
 * - If both multipliers are "0" the EA trades like a single-position system (no grid).
 * - If "Pyramid.Multiplier" is between "0" and "1" the EA trades on the winning side like a regular pyramiding system.
 * - If "Pyramid.Multiplier" is greater than "1" the EA trades on the winning side like a reverse-martingale system.
 * - If "Martingale.Multiplier" is greater than "0" the EA trades on the losing side like a regular martingale system.
 *
 *  @link  http://www.rosasurfer.com/.mt4/The%20Grid.mp4#                                                          [The Grid]
 *  @link  https://www.youtube.com/watch?v=NTM_apWWcO0#                      [Duel - I've looked at life from both sides now]
 */
#include <stddefines.mqh>
int   __InitFlags[] = {INIT_TIMEZONE, INIT_BUFFERED_LOG, INIT_NO_EXTERNAL_REPORTING};
int __DeinitFlags[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string   Sequence.ID            = "";                                  // instance to load from a file, format /T?[0-9]{4}/

extern string   GridDirection          = "Long | Short | Both*";              //
extern string   GridVolatility         = "{percent}";                         // drawdown on a ADR move to the losing side
extern string   GridSize               = "";                                  // grid spacing in pip or quote unit (2 | 3.4 | 123.00)
extern double   UnitSize               = 0;                                   // lots at the first grid level
extern int      MaxUnits               = 10;                                  // max. number of units per direction

extern double   Pyramid.Multiplier     = 1;                                   // unitsize multiplier per grid level on the winning side
extern double   Martingale.Multiplier  = 0;                                   // unitsize multiplier per grid level on the losing side

extern string   StopConditions         = "";                                  // @[bid|ask|price](double) | @profit(double[%]) | @loss(double[%])
extern bool     ShowProfitInPercent    = false;                               // whether PL is displayed as absolute or percentage value

extern datetime Sessionbreak.StartTime = D'1970.01.01 23:56:00';              // server time, the date part is ignored
extern datetime Sessionbreak.EndTime   = D'1970.01.01 00:02:10';              // server time, the date part is ignored

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <rsfLib.mqh>
#include <functions/HandleCommands.mqh>
#include <functions/ta/ADR.mqh>
#include <structs/rsf/OrderExecution.mqh>

#define STRATEGY_ID         105                    // unique strategy id between 101-1023 (10 bit)

#define SID_MIN            1000                    // valid range of sequence id values
#define SID_MAX            9999

#define STATUS_UNDEFINED      0                    // sequence status values
#define STATUS_WAITING        1
#define STATUS_PROGRESSING    2
#define STATUS_STOPPED        3

#define SIGNAL_PRICE_TIME     1                    // a price and/or time condition
#define SIGNAL_TREND          2
#define SIGNAL_TAKEPROFIT     3
#define SIGNAL_STOPLOSS       4
#define SIGNAL_SESSION_BREAK  5

#define D_LONG                TRADE_DIRECTION_LONG
#define D_SHORT               TRADE_DIRECTION_SHORT
#define D_BOTH                TRADE_DIRECTION_BOTH

#define HI_CYCLE              0                    // order history indexes
#define HI_STARTTIME          1
#define HI_STARTPRICE         2
#define HI_GRIDBASE           3                    // TODO: reposition gridbase the next time history gets extended
#define HI_STOPTIME           4
#define HI_STOPPRICE          5
#define HI_TOTALPROFIT        6
#define HI_MAXPROFIT          7
#define HI_MAXDRAWDOWN        8
#define HI_TICKET             9
#define HI_LEVEL             10
#define HI_LOTS              11
#define HI_PENDINGTYPE       12
#define HI_PENDINGTIME       13
#define HI_PENDINGPRICE      14
#define HI_OPENTYPE          15
#define HI_OPENTIME          16
#define HI_OPENPRICE         17
#define HI_CLOSETIME         18
#define HI_CLOSEPRICE        19
#define HI_SWAP              20
#define HI_COMMISSION        21
#define HI_PROFIT            22

// sequence data
int      sequence.id;                              // instance id between 1000-9999
datetime sequence.created;                         //
bool     sequence.isTest;                          // whether the sequence is a test (which can be loaded into an online chart)
string   sequence.name = "";                       // "[LS].{sequence-id}"
int      sequence.cycle;                           // start/stop cycle: 1...+n
int      sequence.status;                          //
int      sequence.direction;                       //
bool     sequence.pyramidEnabled;                  // whether the sequence scales in on the winning side (pyramid)
bool     sequence.martingaleEnabled;               // whether the sequence scales in on the losing side (martingale)
double   sequence.gridsize;                        //
double   sequence.unitsize;                        // lots at the first grid level
double   sequence.gridvola;                        //
double   sequence.gridbase;                        //
datetime sequence.startTime;                       //
double   sequence.startPrice;                      //
double   sequence.startEquity;                     //
datetime sequence.stopTime;                        //
double   sequence.stopPrice;                       //

double   sequence.openLots;                        // open net lots: long.totalLots - short.totalLots
double   sequence.avgOpenPrice;                    // average open price of the net position (without commissions and swaps)
double   sequence.floatingCommission;              // commission of the floating open position (without hedged parts)
double   sequence.floatingSwap;                    // swap of the floating open position (without hedged parts)
double   sequence.floatingPL;                      // PL of the floating open position (incl. floating commissions and swaps)
double   sequence.hedgedPL;                        // PL of a hedged open position (incl. hedged commissions and swaps)
double   sequence.openPL;                          // PL of all open positions: floatingPL + hedgedPL
double   sequence.closedPL;                        // PL of all closed positions
double   sequence.totalPL;                         // total PL of the sequence: openPL + closedPL
double   sequence.maxProfit;                       // max. observed total sequence profit:   0...+n
double   sequence.maxDrawdown;                     // max. observed total sequence drawdown: -n...0

double   sequence.tpPrice;                         //
double   sequence.slPrice;                         //

// order management
bool     long.enabled;
int      long.ticket      [];                      // tickets are ordered ascending by grid level
int      long.level       [];                      // grid level: -n...-1 | +1...+n
double   long.lots        [];
int      long.pendingType [];
datetime long.pendingTime [];
double   long.pendingPrice[];                      // gridlevel price
int      long.openType    [];
datetime long.openTime    [];
double   long.openPrice   [];
datetime long.closeTime   [];
double   long.closePrice  [];
double   long.swap        [];
double   long.commission  [];
double   long.profit      [];
double   long.history     [][23];                  // history of closed long orders
double   long.openLots;                            // open long lots: 0...+n
double   long.slippage;                            // overall slippage of the long side
double   long.openPL;
double   long.closedPL;
double   long.bePrice;
int      long.minLevel = INT_MAX;                  // lowest reached grid level
int      long.maxLevel = INT_MIN;                  // highest reached grid level

bool     short.enabled;
int      short.ticket      [];                     // tickets are ordered ascending by grid level
int      short.level       [];                     // grid level: -n...-1 | +1...+n
double   short.lots        [];
int      short.pendingType [];
datetime short.pendingTime [];
double   short.pendingPrice[];                     // gridlevel price
int      short.openType    [];
datetime short.openTime    [];
double   short.openPrice   [];
datetime short.closeTime   [];
double   short.closePrice  [];
double   short.swap        [];
double   short.commission  [];
double   short.profit      [];
double   short.history     [][23];                 // history of closed short orders
double   short.openLots;                           // open short lots: 0...+n
double   short.slippage;                           // overall slippage of the short side
double   short.openPL;
double   short.closedPL;
double   short.bePrice;
int      short.minLevel = INT_MAX;                 // lowest reached grid level
int      short.maxLevel = INT_MIN;                 // highest reached grid level

// stop conditions ("OR" combined)
bool     stop.price.condition;                     // whether a stop price condition is active
int      stop.price.type;                          // PRICE_BID | PRICE_ASK | PRICE_MEDIAN
double   stop.price.value;
double   stop.price.lastValue;
string   stop.price.description = "";

bool     stop.profitAbs.condition;                 // whether an absolute takeprofit condition is active
double   stop.profitAbs.value;
string   stop.profitAbs.description = "";

bool     stop.profitPct.condition;                 // whether a percentage takeprofit condition is active
double   stop.profitPct.value;
double   stop.profitPct.absValue    = INT_MAX;
string   stop.profitPct.description = "";

bool     stop.lossAbs.condition;                   // whether an absolute stoploss condition is active
double   stop.lossAbs.value;
string   stop.lossAbs.description = "";

bool     stop.lossPct.condition;                   // whether a percentage stoploss condition is active
double   stop.lossPct.value;
double   stop.lossPct.absValue    = INT_MIN;
string   stop.lossPct.description = "";

// sessionbreak management
datetime sessionbreak.starttime;                   // configurable via inputs and framework config
datetime sessionbreak.endtime;

// caching vars to speed-up ShowStatus()
string   sGridParameters  = "";
string   sGridVolatility  = "";
string   sStopConditions  = "";
string   sTotalLots       = "";
string   sOpenLongLots    = "";
string   sOpenShortLots   = "";
string   sSequenceBePrice = "";
string   sSequenceTpPrice = "";
string   sSequenceSlPrice = "";
string   sSequenceTotalPL = "";
string   sSequencePlStats = "";
string   sCycleStats      = "";

// debug settings                                  // configurable via framework config, see afterInit()
bool     test.onStopPause        = false;          // whether to pause a test after StopSequence()
bool     test.reduceStatusWrites = true;           // whether to reduce status file writing in tester

#include <apps/duel/init.mqh>
#include <apps/duel/deinit.mqh>


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   int signal;
   if (__isChart) HandleCommands();                            // process incoming commands

   if (sequence.status == STATUS_WAITING) {
      if (IsStartSignal(signal)) StartSequence(signal);
   }
   else if (sequence.status == STATUS_PROGRESSING) {           // manage a running sequence
      bool gridChanged=false, gridError=false;                 // whether the current gridlevel changed or a grid error occurred

      if (UpdateStatus(gridChanged, gridError)) {              // check pending orders and open positions
         if      (gridError)            StopSequence(NULL);
         else if (IsStopSignal(signal)) StopSequence(signal);
         else if (gridChanged)          UpdatePendingOrders(true);
      }
   }
   else if (sequence.status == STATUS_STOPPED) {
   }

   return(catch("onTick(1)"));

   // dummy call
   MakeScreenshot();
}


/**
 * Process an incoming command.
 *
 * @param  string cmd    - command name
 * @param  string params - command parameters
 * @param  int    keys   - combination of pressed modifier keys
 *
 * @return bool - success status of the executed command
 */
bool onCommand(string cmd, string params, int keys) {
   string fullCmd = cmd +":"+ params +":"+ keys;

   if (cmd == "start") {
      switch (sequence.status) {
         case STATUS_WAITING:
            logInfo("onCommand(2)  "+ sequence.name +" "+ DoubleQuoteStr(fullCmd));
            return(StartSequence(NULL));
      }
   }
   else if (cmd == "stop") {
      switch (sequence.status) {
         case STATUS_WAITING:
         case STATUS_PROGRESSING:
            logInfo("onCommand(3)  "+ sequence.name +" "+ DoubleQuoteStr(fullCmd));
            return(StopSequence(NULL));
      }
   }
   else if (cmd == "resume") {
      switch (sequence.status) {
         case STATUS_STOPPED:
            logInfo("onCommand(4)  "+ sequence.name +" "+ DoubleQuoteStr(fullCmd));
            return(ResumeSequence(NULL));
      }
   }
   else if (cmd == "toggle-open-orders") {
      return(ToggleOpenOrders());
   }
   else if (cmd == "toggle-trade-history") {
      return(ToggleTradeHistory());
   }
   else return(!logNotice("onCommand(5)  "+ sequence.name +" unsupported command: "+ DoubleQuoteStr(cmd)));

   return(!logWarn("onCommand(6)  "+ sequence.name +" cannot execute command "+ DoubleQuoteStr(cmd) +" in status "+ StatusToStr(sequence.status)));
}


/**
 * Toggle the display of open orders.
 *
 * @return bool - success status
 */
bool ToggleOpenOrders() {
   // read current status and toggle it
   bool showOrders = !GetOpenOrderDisplayStatus();

   // ON: display open orders
   if (showOrders) {
      int orders = ShowOpenOrders();
      if (orders == -1) return(false);
      if (!orders) {                                  // Without open orders status must be reset to have the "off" section
         showOrders = false;                          // remove any existing open order markers.
         PlaySoundEx("Plonk.wav");
      }
   }

   // OFF: remove open order markers
   if (!showOrders) {
      for (int i=ObjectsTotal()-1; i >= 0; i--) {
         string name = ObjectName(i);

         if (StringGetChar(name, 0) == '#') {
            if (ObjectType(name)==OBJ_ARROW) {
               int arrow = ObjectGet(name, OBJPROP_ARROWCODE);
               color clr = ObjectGet(name, OBJPROP_COLOR);

               if (arrow == SYMBOL_ORDEROPEN) {
                  if (clr!=CLR_OPEN_PENDING && clr!=CLR_OPEN_LONG && clr!=CLR_OPEN_SHORT) continue;
               }
               else if (arrow == SYMBOL_ORDERCLOSE) {
                  if (clr!=CLR_OPEN_TAKEPROFIT && clr!=CLR_OPEN_STOPLOSS) continue;
               }
               ObjectDelete(name);
            }
         }
      }
   }

   // store current status in the chart
   SetOpenOrderDisplayStatus(showOrders);

   if (__isTesting) WindowRedraw();
   return(!catch("ToggleOpenOrders(1)"));
}


/**
 * Resolve the current 'ShowOpenOrders' display status.
 *
 * @return bool - ON/OFF
 */
bool GetOpenOrderDisplayStatus() {
   bool status = false;

   // look-up a status stored in the chart
   string label = "rsf."+ ProgramName() +".ShowOpenOrders";
   if (ObjectFind(label) != -1) {
      string sValue = ObjectDescription(label);
      if (StrIsInteger(sValue))
         status = (StrToInteger(sValue) != 0);
   }
   return(status);
}


/**
 * Store the given 'ShowOpenOrders' display status.
 *
 * @param  bool status - display status
 *
 * @return bool - success status
 */
bool SetOpenOrderDisplayStatus(bool status) {
   status = status!=0;

   // store status in the chart (for terminal restarts)
   string label = "rsf."+ ProgramName() +".ShowOpenOrders";
   if (ObjectFind(label) == -1) ObjectCreate(label, OBJ_LABEL, 0, 0, 0);
   ObjectSet(label, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   ObjectSetText(label, ""+ status);

   return(!catch("SetOpenOrderDisplayStatus(1)"));
}


/**
 * Display the currently open orders.
 *
 * @return int - number of displayed orders or EMPTY (-1) in case of errors
 */
int ShowOpenOrders() {
   string orderTypes[] = {"buy", "sell", "buy limit", "sell limit", "buy stop", "sell stop"}, instanceName=ProgramName() +"."+ sequence.name, label="";
   color colors[] = {CLR_OPEN_LONG, CLR_OPEN_SHORT};

   // long
   int orders = ArraySize(long.ticket), openOrders=0;
   for (int i=0; i < orders; i++) {
      if (long.closeTime[i] != 0) continue;        // skip closed orders

      if (long.openType[i] == OP_UNDEFINED) {
         // pending orders
         label = StringConcatenate("#", long.ticket[i], " ", orderTypes[long.pendingType[i]], " ", NumberToStr(long.lots[i], ".1+"), " at ", NumberToStr(long.pendingPrice[i], PriceFormat));
         if (ObjectFind(label) == -1) ObjectCreate(label, OBJ_ARROW, 0, 0, 0);
         ObjectSet    (label, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
         ObjectSet    (label, OBJPROP_COLOR,     CLR_OPEN_PENDING);
         ObjectSet    (label, OBJPROP_TIME1,     Tick.time);
         ObjectSet    (label, OBJPROP_PRICE1,    long.pendingPrice[i]);
         ObjectSetText(label, instanceName +"."+ NumberToStr(long.level[i], "+."));
      }
      else {
         // open positions
         label = StringConcatenate("#", long.ticket[i], " ", orderTypes[long.openType[i]], " ", NumberToStr(long.lots[i], ".1+"), " at ", NumberToStr(long.openPrice[i], PriceFormat));
         if (ObjectFind(label) == -1) ObjectCreate(label, OBJ_ARROW, 0, 0, 0);
         ObjectSet    (label, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
         ObjectSet    (label, OBJPROP_COLOR,     colors[long.openType[i]]);
         ObjectSet    (label, OBJPROP_TIME1,     long.openTime[i]);
         ObjectSet    (label, OBJPROP_PRICE1,    long.openPrice[i]);
         ObjectSetText(label, instanceName +"."+ NumberToStr(long.level[i], "+."));
      }
      openOrders++;
   }

   // short
   orders = ArraySize(short.ticket);
   for (i=0; i < orders; i++) {
      if (short.closeTime[i] != 0) continue;       // skip closed orders

      if (short.openType[i] == OP_UNDEFINED) {
         // pending orders
         label = StringConcatenate("#", short.ticket[i], " ", orderTypes[short.pendingType[i]], " ", NumberToStr(short.lots[i], ".1+"), " at ", NumberToStr(short.pendingPrice[i], PriceFormat));
         if (ObjectFind(label) == -1) ObjectCreate(label, OBJ_ARROW, 0, 0, 0);
         ObjectSet    (label, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
         ObjectSet    (label, OBJPROP_COLOR,     CLR_OPEN_PENDING);
         ObjectSet    (label, OBJPROP_TIME1,     Tick.time);
         ObjectSet    (label, OBJPROP_PRICE1,    short.pendingPrice[i]);
         ObjectSetText(label, instanceName +"."+ NumberToStr(short.level[i], "+."));
      }
      else {
         // open positions
         label = StringConcatenate("#", short.ticket[i], " ", orderTypes[short.openType[i]], " ", NumberToStr(short.lots[i], ".1+"), " at ", NumberToStr(short.openPrice[i], PriceFormat));
         if (ObjectFind(label) == -1) ObjectCreate(label, OBJ_ARROW, 0, 0, 0);
         ObjectSet    (label, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
         ObjectSet    (label, OBJPROP_COLOR,     colors[short.openType[i]]);
         ObjectSet    (label, OBJPROP_TIME1,     short.openTime[i]);
         ObjectSet    (label, OBJPROP_PRICE1,    short.openPrice[i]);
         ObjectSetText(label, instanceName +"."+ NumberToStr(short.level[i], "+."));
      }
      openOrders++;
   }

   if (!catch("ShowOpenOrders(1)"))
      return(openOrders);
   return(EMPTY);
}


/**
 * Toggle the display of closed trades.
 *
 * @return bool - success status
 */
bool ToggleTradeHistory() {
   // read current status and toggle it
   bool showHistory = !GetTradeHistoryDisplayStatus();

   // ON: display closed trades
   if (showHistory) {
      int trades = ShowTradeHistory();
      if (trades == -1) return(false);
      if (!trades) {                                  // Without closed trades status must be reset to have the "off" section
         showHistory = false;                         // remove any existing closed trade markers.
         PlaySoundEx("Plonk.wav");
      }
   }

   // OFF: remove closed trade markers
   if (!showHistory) {
      for (int i=ObjectsTotal()-1; i >= 0; i--) {
         string name = ObjectName(i);

         if (StringGetChar(name, 0) == '#') {
            if (ObjectType(name) == OBJ_ARROW) {
               int arrow = ObjectGet(name, OBJPROP_ARROWCODE);
               color clr = ObjectGet(name, OBJPROP_COLOR);

               if (arrow == SYMBOL_ORDEROPEN) {
                  if (clr!=CLR_CLOSED_LONG && clr!=CLR_CLOSED_SHORT) continue;
               }
               else if (arrow == SYMBOL_ORDERCLOSE) {
                  if (clr!=CLR_CLOSED) continue;
               }
            }
            else if (ObjectType(name) != OBJ_TREND) continue;
            ObjectDelete(name);
         }
      }
   }

   // store current status in the chart
   SetTradeHistoryDisplayStatus(showHistory);

   if (__isTesting) WindowRedraw();
   return(!catch("ToggleTradeHistory(1)"));
}


/**
 * Resolve the current 'ShowTradeHistory' display status.
 *
 * @return bool - ON/OFF
 */
bool GetTradeHistoryDisplayStatus() {
   bool status = false;

   // look-up a status stored in the chart
   string label = "rsf."+ ProgramName() +".ShowTradeHistory";
   if (ObjectFind(label) != -1) {
      string sValue = ObjectDescription(label);
      if (StrIsInteger(sValue))
         status = (StrToInteger(sValue) != 0);
   }
   return(status);
}


/**
 * Store the given 'ShowTradeHistory' display status.
 *
 * @param  bool status - display status
 *
 * @return bool - success status
 */
bool SetTradeHistoryDisplayStatus(bool status) {
   status = status!=0;

   // store status in the chart
   string label = "rsf."+ ProgramName() +".ShowTradeHistory";
   if (ObjectFind(label) == -1)
      ObjectCreate(label, OBJ_LABEL, 0, 0, 0);
   ObjectSet(label, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   ObjectSetText(label, ""+ status);

   return(!catch("SetTradeHistoryDisplayStatus(1)"));
}


/**
 * Display closed trades.
 *
 * @return int - number of displayed trades or EMPTY (-1) in case of errors
 */
int ShowTradeHistory() {
   string openLabel="", closeLabel="", lineLabel="", sOpenPrice="", sClosePrice="", text="";
   int closedTrades = 0;

   // process closed trades of the current cycle
   if (sequence.status == STATUS_STOPPED) {
      // long
      int orders = ArraySize(long.ticket);
      for (int i=0; i < orders; i++) {
         if (!long.closeTime[i])               continue;    // skip open tickets
         if (long.openType[i] == OP_UNDEFINED) continue;    // skip cancelled orders

         sOpenPrice  = NumberToStr(long.openPrice [i], PriceFormat);
         sClosePrice = NumberToStr(long.closePrice[i], PriceFormat);
         text        = "Duel.L."+ sequence.id +"."+ NumberToStr(long.level[i], "+.");

         // open marker
         openLabel = StringConcatenate("#", long.ticket[i], " buy ", NumberToStr(long.lots[i], ".1+"), " at ", sOpenPrice);
         if (ObjectFind(openLabel) == -1) ObjectCreate(openLabel, OBJ_ARROW, 0, 0, 0);
         ObjectSet    (openLabel, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
         ObjectSet    (openLabel, OBJPROP_COLOR,     CLR_CLOSED_LONG);
         ObjectSet    (openLabel, OBJPROP_TIME1,     long.openTime[i]);
         ObjectSet    (openLabel, OBJPROP_PRICE1,    long.openPrice[i]);
         ObjectSetText(openLabel, text);

         // trend line
         lineLabel = StringConcatenate("#", long.ticket[i], " ", sOpenPrice, " -> ", sClosePrice);
         if (ObjectFind(lineLabel) == -1) ObjectCreate(lineLabel, OBJ_TREND, 0, 0, 0, 0, 0);
         ObjectSet(lineLabel, OBJPROP_RAY,    false);
         ObjectSet(lineLabel, OBJPROP_STYLE,  STYLE_DOT);
         ObjectSet(lineLabel, OBJPROP_COLOR,  Blue);
         ObjectSet(lineLabel, OBJPROP_BACK,   true);
         ObjectSet(lineLabel, OBJPROP_TIME1,  long.openTime[i]);
         ObjectSet(lineLabel, OBJPROP_PRICE1, long.openPrice[i]);
         ObjectSet(lineLabel, OBJPROP_TIME2,  long.closeTime[i]);
         ObjectSet(lineLabel, OBJPROP_PRICE2, long.closePrice[i]);

         // close marker
         closeLabel = StringConcatenate(openLabel, " close at ", sClosePrice);
         if (ObjectFind(closeLabel) == -1) ObjectCreate(closeLabel, OBJ_ARROW, 0, 0, 0);
         ObjectSet    (closeLabel, OBJPROP_ARROWCODE, SYMBOL_ORDERCLOSE);
         ObjectSet    (closeLabel, OBJPROP_COLOR,     CLR_CLOSED);
         ObjectSet    (closeLabel, OBJPROP_TIME1,     long.closeTime[i]);
         ObjectSet    (closeLabel, OBJPROP_PRICE1,    long.closePrice[i]);
         ObjectSetText(closeLabel, text);
         closedTrades++;
      }

      // short
      orders = ArraySize(short.ticket);
      for (i=0; i < orders; i++) {
         if (!short.closeTime[i])               continue;   // skip open tickets
         if (short.openType[i] == OP_UNDEFINED) continue;   // skip cancelled orders

         sOpenPrice  = NumberToStr(short.openPrice [i], PriceFormat);
         sClosePrice = NumberToStr(short.closePrice[i], PriceFormat);
         text        = "Duel.S."+ sequence.id +"."+ NumberToStr(short.level[i], "+.");

         // open marker
         openLabel = StringConcatenate("#", short.ticket[i], " sell ", NumberToStr(short.lots[i], ".1+"), " at ", sOpenPrice);
         if (ObjectFind(openLabel) == -1) ObjectCreate(openLabel, OBJ_ARROW, 0, 0, 0);
         ObjectSet    (openLabel, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
         ObjectSet    (openLabel, OBJPROP_COLOR,     CLR_CLOSED_SHORT);
         ObjectSet    (openLabel, OBJPROP_TIME1,     short.openTime[i]);
         ObjectSet    (openLabel, OBJPROP_PRICE1,    short.openPrice[i]);
         ObjectSetText(openLabel, text);

         // trend line
         lineLabel = StringConcatenate("#", short.ticket[i], " ", sOpenPrice, " -> ", sClosePrice);
         if (ObjectFind(lineLabel) == -1) ObjectCreate(lineLabel, OBJ_TREND, 0, 0, 0, 0, 0);
         ObjectSet(lineLabel, OBJPROP_RAY,   false);
         ObjectSet(lineLabel, OBJPROP_STYLE, STYLE_DOT);
         ObjectSet(lineLabel, OBJPROP_COLOR, Red);
         ObjectSet(lineLabel, OBJPROP_BACK,  true);
         ObjectSet(lineLabel, OBJPROP_TIME1,  short.openTime[i]);
         ObjectSet(lineLabel, OBJPROP_PRICE1, short.openPrice[i]);
         ObjectSet(lineLabel, OBJPROP_TIME2,  short.closeTime[i]);
         ObjectSet(lineLabel, OBJPROP_PRICE2, short.closePrice[i]);

         // close marker
         closeLabel = StringConcatenate(openLabel, " close at ", sClosePrice);
         if (ObjectFind(closeLabel) == -1) ObjectCreate(closeLabel, OBJ_ARROW, 0, 0, 0);
         ObjectSet    (closeLabel, OBJPROP_ARROWCODE, SYMBOL_ORDERCLOSE);
         ObjectSet    (closeLabel, OBJPROP_COLOR,     CLR_CLOSED);
         ObjectSet    (closeLabel, OBJPROP_TIME1,     short.closeTime[i]);
         ObjectSet    (closeLabel, OBJPROP_PRICE1,    short.closePrice[i]);
         ObjectSetText(closeLabel, text);
         closedTrades++;
      }
   }

   // process long trades of archived cycles
   orders = ArrayRange(long.history, 0);
   for (i=0; i < orders; i++) {
      if (!long.history[i][HI_CLOSETIME])               continue;       // skip open tickets     (should never happen)
      if (long.history[i][HI_OPENTYPE] == OP_UNDEFINED) continue;       // skip cancelled orders (should never happen)

      sOpenPrice  = NumberToStr(long.history[i][HI_OPENPRICE ], PriceFormat);
      sClosePrice = NumberToStr(long.history[i][HI_CLOSEPRICE], PriceFormat);
      text        = "Duel.L."+ sequence.id +"."+ NumberToStr(long.history[i][HI_LEVEL], "+.");

      // open marker
      openLabel = StringConcatenate("#", _int(long.history[i][HI_TICKET]), " buy ", NumberToStr(long.history[i][HI_LOTS], ".1+"), " at ", sOpenPrice);
      if (ObjectFind(openLabel) == -1) ObjectCreate(openLabel, OBJ_ARROW, 0, 0, 0);
      ObjectSet    (openLabel, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
      ObjectSet    (openLabel, OBJPROP_COLOR,     CLR_CLOSED_LONG);
      ObjectSet    (openLabel, OBJPROP_TIME1,     long.history[i][HI_OPENTIME]);
      ObjectSet    (openLabel, OBJPROP_PRICE1,    long.history[i][HI_OPENPRICE]);
      ObjectSetText(openLabel, text);

      // trend line
      lineLabel = StringConcatenate("#", _int(long.history[i][HI_TICKET]), " ", sOpenPrice, " -> ", sClosePrice);
      if (ObjectFind(lineLabel) == -1) ObjectCreate(lineLabel, OBJ_TREND, 0, 0, 0, 0, 0);
      ObjectSet(lineLabel, OBJPROP_RAY,    false);
      ObjectSet(lineLabel, OBJPROP_STYLE,  STYLE_DOT);
      ObjectSet(lineLabel, OBJPROP_COLOR,  Blue);
      ObjectSet(lineLabel, OBJPROP_BACK,   true);
      ObjectSet(lineLabel, OBJPROP_TIME1,  long.history[i][HI_OPENTIME]);
      ObjectSet(lineLabel, OBJPROP_PRICE1, long.history[i][HI_OPENPRICE]);
      ObjectSet(lineLabel, OBJPROP_TIME2,  long.history[i][HI_CLOSETIME]);
      ObjectSet(lineLabel, OBJPROP_PRICE2, long.history[i][HI_CLOSEPRICE]);

      // close marker
      closeLabel = StringConcatenate(openLabel, " close at ", sClosePrice);
      if (ObjectFind(closeLabel) == -1) ObjectCreate(closeLabel, OBJ_ARROW, 0, 0, 0);
      ObjectSet    (closeLabel, OBJPROP_ARROWCODE, SYMBOL_ORDERCLOSE);
      ObjectSet    (closeLabel, OBJPROP_COLOR,     CLR_CLOSED);
      ObjectSet    (closeLabel, OBJPROP_TIME1,     long.history[i][HI_CLOSETIME]);
      ObjectSet    (closeLabel, OBJPROP_PRICE1,    long.history[i][HI_CLOSEPRICE]);
      ObjectSetText(closeLabel, text);
      closedTrades++;
   }

   // process short trades of archived cycles
   orders = ArrayRange(short.history, 0);
   for (i=0; i < orders; i++) {
      if (!short.history[i][HI_CLOSETIME])               continue;     // skip open tickets     (should never happen)
      if (short.history[i][HI_OPENTYPE] == OP_UNDEFINED) continue;     // skip cancelled orders (should never happen)

      sOpenPrice  = NumberToStr(short.history[i][HI_OPENPRICE ], PriceFormat);
      sClosePrice = NumberToStr(short.history[i][HI_CLOSEPRICE], PriceFormat);
      text        = "Duel.S."+ sequence.id +"."+ NumberToStr(short.history[i][HI_LEVEL], "+.");

      // open marker
      openLabel = StringConcatenate("#", _int(short.history[i][HI_TICKET]), " buy ", NumberToStr(short.history[i][HI_LOTS], ".1+"), " at ", sOpenPrice);
      if (ObjectFind(openLabel) == -1) ObjectCreate(openLabel, OBJ_ARROW, 0, 0, 0);
      ObjectSet    (openLabel, OBJPROP_ARROWCODE, SYMBOL_ORDEROPEN);
      ObjectSet    (openLabel, OBJPROP_COLOR,     CLR_CLOSED_SHORT);
      ObjectSet    (openLabel, OBJPROP_TIME1,     short.history[i][HI_OPENTIME]);
      ObjectSet    (openLabel, OBJPROP_PRICE1,    short.history[i][HI_OPENPRICE]);
      ObjectSetText(openLabel, text);

      // trend line
      lineLabel = StringConcatenate("#", _int(short.history[i][HI_TICKET]), " ", sOpenPrice, " -> ", sClosePrice);
      if (ObjectFind(lineLabel) == -1) ObjectCreate(lineLabel, OBJ_TREND, 0, 0, 0, 0, 0);
      ObjectSet(lineLabel, OBJPROP_RAY,   false);
      ObjectSet(lineLabel, OBJPROP_STYLE, STYLE_DOT);
      ObjectSet(lineLabel, OBJPROP_COLOR, Red);
      ObjectSet(lineLabel, OBJPROP_BACK,  true);
      ObjectSet(lineLabel, OBJPROP_TIME1,  short.history[i][HI_OPENTIME]);
      ObjectSet(lineLabel, OBJPROP_PRICE1, short.history[i][HI_OPENPRICE]);
      ObjectSet(lineLabel, OBJPROP_TIME2,  short.history[i][HI_CLOSETIME]);
      ObjectSet(lineLabel, OBJPROP_PRICE2, short.history[i][HI_CLOSEPRICE]);

      // close marker
      closeLabel = StringConcatenate(openLabel, " close at ", sClosePrice);
      if (ObjectFind(closeLabel) == -1) ObjectCreate(closeLabel, OBJ_ARROW, 0, 0, 0);
      ObjectSet    (closeLabel, OBJPROP_ARROWCODE, SYMBOL_ORDERCLOSE);
      ObjectSet    (closeLabel, OBJPROP_COLOR,     CLR_CLOSED);
      ObjectSet    (closeLabel, OBJPROP_TIME1,     short.history[i][HI_CLOSETIME]);
      ObjectSet    (closeLabel, OBJPROP_PRICE1,    short.history[i][HI_CLOSEPRICE]);
      ObjectSetText(closeLabel, text);
      closedTrades++;
   }

   if (!catch("ShowTradeHistory(1)"))
      return(closedTrades);
   return(EMPTY);
}


/**
 * Whether a start condition is satisfied for a waiting sequence.
 *
 * @param  _Out_ int &signal - variable receiving the identifier of the satisfied condition
 *
 * @return bool
 */
bool IsStartSignal(int &signal) {
   signal = NULL;
   if (last_error || sequence.status!=STATUS_WAITING) return(false);

   if (IsTradeSessionBreak()) {
      return(false);
   }

   if (__isTesting) {
      // tester: auto-start
      if (!ArraySize(long.ticket) && !ArraySize(short.ticket)) return(true);
   }
   else {
      // online: not yet supported for this EA
   }
   return(false);
}


/**
 * Whether a stop condition is satisfied for a progressing sequence.
 *
 * @param  _Out_ int &signal - variable receiving the signal identifier of the satisfied condition
 *
 * @return bool
 */
bool IsStopSignal(int &signal) {
   signal = NULL;
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("IsStopSignal(1)  "+ sequence.name +" cannot check stop signal of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   string message = "";

   // stop.price: satisfied when current price touches or crossses the limit-------------------------------------------------
   if (stop.price.condition) {
      bool triggered = false;
      double price;
      switch (stop.price.type) {
         case PRICE_BID:    price =  Bid;        break;
         case PRICE_ASK:    price =  Ask;        break;
         case PRICE_MEDIAN: price = (Bid+Ask)/2; break;
      }
      if (stop.price.lastValue != 0) {
         if (stop.price.lastValue < stop.price.value) triggered = (price >= stop.price.value);  // price crossed upwards
         else                                         triggered = (price <= stop.price.value);  // price crossed downwards
      }
      stop.price.lastValue = price;

      if (triggered) {
         if (IsLogNotice()) logNotice("IsStopSignal(2)  "+ sequence.name +" stop condition \"@"+ stop.price.description +"\" satisfied (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
         signal = SIGNAL_PRICE_TIME;
         return(true);
      }
   }

   // stop.profitAbs: -------------------------------------------------------------------------------------------------------
   if (stop.profitAbs.condition) {
      if (sequence.totalPL >= stop.profitAbs.value) {
         if (IsLogNotice()) logNotice("IsStopSignal(5)  "+ sequence.name +" stop condition \"@"+ stop.profitAbs.description +"\" satisfied (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
         signal = SIGNAL_TAKEPROFIT;
         return(true);
      }
   }

   // stop.profitPct: -------------------------------------------------------------------------------------------------------
   if (stop.profitPct.condition) {
      if (stop.profitPct.absValue == INT_MAX)
         stop.profitPct.absValue = stop.profitPct.AbsValue();

      if (sequence.totalPL >= stop.profitPct.absValue) {
         if (IsLogNotice()) logNotice("IsStopSignal(6)  "+ sequence.name +" stop condition \"@"+ stop.profitPct.description +"\" satisfied (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
         signal = SIGNAL_TAKEPROFIT;
         return(true);
      }
   }

   // stop.lossAbs: ---------------------------------------------------------------------------------------------------------
   if (stop.lossAbs.condition) {
      if (sequence.totalPL <= stop.lossAbs.value) {
         if (IsLogNotice()) logNotice("IsStopSignal(7)  "+ sequence.name +" stop condition \"@"+ stop.lossAbs.description +"\" satisfied (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
         signal = SIGNAL_STOPLOSS;
         return(true);
      }
   }

   // stop.lossPct: ---------------------------------------------------------------------------------------------------------
   if (stop.lossPct.condition) {
      if (stop.lossPct.absValue == INT_MIN)
         stop.lossPct.absValue = stop.lossPct.AbsValue();

      if (sequence.totalPL <= stop.lossPct.absValue) {
         if (IsLogNotice()) logNotice("IsStopSignal(8)  "+ sequence.name +" stop condition \"@"+ stop.lossPct.description +"\" satisfied (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
         signal = SIGNAL_STOPLOSS;
         return(true);
      }
   }

   return(false);
}


/**
 * Return the absolute value of a percentage TakeProfit condition.
 *
 * @return double - absolute value or INT_MAX if no percentage TakeProfit was configured
 */
double stop.profitPct.AbsValue() {
   if (stop.profitPct.condition) {
      if (stop.profitPct.absValue == INT_MAX) {
         double startEquity = sequence.startEquity;
         if (!startEquity) startEquity = AccountEquity() - AccountCredit() + GetExternalAssets();
         return(stop.profitPct.value/100 * startEquity);
      }
   }
   return(stop.profitPct.absValue);
}


/**
 * Return the absolute value of a percentage StopLoss condition.
 *
 * @return double - absolute value or INT_MIN if no percentage StopLoss was configured
 */
double stop.lossPct.AbsValue() {
   if (stop.lossPct.condition) {
      if (stop.lossPct.absValue == INT_MIN) {
         double startEquity = sequence.startEquity;
         if (!startEquity) startEquity = AccountEquity() - AccountCredit() + GetExternalAssets();
         return(stop.lossPct.value/100 * startEquity);
      }
   }
   return(stop.lossPct.absValue);
}


/**
 * Whether the current server time falls into a sessionbreak. After function return the global vars sessionbreak.starttime
 * and sessionbreak.endtime are always up-to-date.
 *
 * @return bool
 */
bool IsTradeSessionBreak() {
   if (last_error != NULL) return(false);

   datetime srvNow = TimeServer();

   // check whether to recalculate sessionbreak start/end times
   if (srvNow >= sessionbreak.endtime) {
      int startOffset = Sessionbreak.StartTime % DAYS;            // sessionbreak start offset in seconds since Midnight server time
      int endOffset   = Sessionbreak.EndTime % DAYS;              // sessionbreak end offset in seconds since Midnight server time

      // calculate today's theoretical sessionbreak end time in SRV and FXT
      datetime srvMidnight = srvNow - srvNow % DAYS;              // today's Midnight in SRV
      datetime srvEndTime  = srvMidnight + endOffset;             // today's theoretical sessionbreak end time in SRV
      datetime fxtNow      = ServerToFxtTime(srvNow);
      datetime fxtMidnight = fxtNow - fxtNow % DAYS;              // today's Midnight in FXT
      datetime fxtEndTime  = fxtMidnight + endOffset;             // today's theoretical sessionbreak end time in FXT

      // determine the next real sessionbreak end time in SRV
      int dow = TimeDayOfWeekEx(fxtEndTime);
      while (srvEndTime <= srvNow || dow==SATURDAY || dow==SUNDAY) {
         srvEndTime += 1*DAY;
         fxtEndTime += 1*DAY;
         dow = TimeDayOfWeekEx(fxtEndTime);
      }
      sessionbreak.endtime = srvEndTime;

      // determine the corresponding (before end) sessionbreak start time
      srvMidnight           = srvEndTime - srvEndTime % DAYS;     // the resume day's Midnight in SRV
      datetime srvStartTime = srvMidnight + startOffset;          // the resume day's theoretical sessionbreak start time in SRV
      fxtMidnight           = fxtEndTime - fxtEndTime % DAYS;     // the resume day's Midnight in FXT
      datetime fxtStartTime = fxtMidnight + startOffset;          // the resume day's theoretical sessionbreak start time in FXT

      dow = TimeDayOfWeekEx(fxtStartTime);
      while (srvStartTime > srvEndTime || dow==SATURDAY || dow==SUNDAY || (dow==MONDAY && fxtStartTime==fxtMidnight)) {
         srvStartTime -= 1*DAY;
         fxtStartTime -= 1*DAY;
         dow = TimeDayOfWeekEx(fxtStartTime);
      }
      sessionbreak.starttime = srvStartTime;

      if (IsLogDebug()) logDebug("IsTradeSessionBreak(1)  "+ sequence.name +" recalculated "+ ifString(srvNow >= sessionbreak.starttime, "current", "next") +" sessionbreak: from "+ GmtTimeFormat(sessionbreak.starttime, "%a, %Y.%m.%d %H:%M:%S") +" to "+ GmtTimeFormat(sessionbreak.endtime, "%a, %Y.%m.%d %H:%M:%S"));
   }

   // perform the actual check
   return(srvNow >= sessionbreak.starttime);                      // here sessionbreak.endtime is always in the future
}


/**
 * Start a waiting sequence.
 *
 * @param  int signal - signal which triggered a start condition or NULL on explicit (i.e. manual) start
 *
 * @return bool - success status
 */
bool StartSequence(int signal) {
   if (sequence.status != STATUS_WAITING) return(!catch("StartSequence(1)  "+ sequence.name +" cannot start "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (!stop.lossAbs.condition && !stop.lossPct.condition) {
      PlaySoundEx("alert.wav");
      MessageBoxEx(ProgramName() +"::StartSequence()", "Cannot start EA without a StopLoss condition!", MB_ICONERROR|MB_OK);
      return(false);
   }
   if (IsLogInfo()) logInfo("StartSequence(2)  "+ sequence.name +" starting sequence...");

   sequence.status      = STATUS_PROGRESSING;
   sequence.startTime   = TimeServer();
   sequence.startEquity = NormalizeDouble(AccountEquity() - AccountCredit() + GetExternalAssets(), 2);
   sequence.stopTime    = 0;
   sequence.stopPrice   = 0;

   double longOpenPrice, shortOpenPrice, dNull;
   if (long.enabled) {                                            // open a long position for level 1
      if (!Grid.AddPosition(D_LONG, 1, longOpenPrice, dNull)) return(false);
   }
   if (short.enabled) {                                           // open a short position for level 1
      if (!Grid.AddPosition(D_SHORT, 1, shortOpenPrice, dNull)) return(false);
   }

   if      (sequence.direction == D_LONG)  sequence.startPrice = longOpenPrice;
   else if (sequence.direction == D_SHORT) sequence.startPrice = shortOpenPrice;
   else                                    sequence.startPrice = (longOpenPrice + shortOpenPrice)/2;
   sequence.startPrice = NormalizeDouble(sequence.startPrice, Digits);
   sequence.gridbase   = sequence.startPrice;

   if (!UpdatePendingOrders()) return(false);                     // update pending orders
   if (IsLogInfo()) logInfo("StartSequence(3)  "+ sequence.name +" sequence started at "+ NumberToStr(sequence.startPrice, PriceFormat) +" (gridbase "+ NumberToStr(sequence.gridbase, PriceFormat) +")");

   ComputeProfit(true);
   ComputeTargets();
   return(SaveStatus());
}


/**
 * Resume a stopped sequence.
 *
 * @param  int signal - signal which triggered a resume condition or NULL on explicit (i.e. manual) resume.
 *
 * @return bool - success status
 */
bool ResumeSequence(int signal) {
   if (sequence.status != STATUS_STOPPED) return(!catch("ResumeSequence(1)  "+ sequence.name +" cannot resume "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (!stop.lossAbs.condition && !stop.lossPct.condition) {
      PlaySoundEx("alert.wav");
      MessageBoxEx(ProgramName() +"::ResumeSequence()", "Cannot resume EA without a StopLoss condition!", MB_ICONERROR|MB_OK);
      return(false);
   }
   if (IsLogInfo()) logInfo("ResumeSequence(2)  "+ sequence.name +" resuming sequence...");

   double oldGridbase=sequence.gridbase, oldStopPrice=sequence.stopPrice, longOpenPrice, shortOpenPrice;

   // archive the stopped sequence cycle
   if (!ArchiveStoppedSequence()) return(false);
   SS.CycleStats();

   // re-initialize sequence data
   sequence.cycle++;
   sequence.status       = STATUS_PROGRESSING;                    // TODO: update TP/SL conditions
   sequence.gridbase     = 0;
   sequence.startTime    = TimeServer();
   sequence.startPrice   = 0;
   sequence.stopTime     = 0;
   sequence.stopPrice    = 0;
   sequence.openLots     = 0;
   sequence.avgOpenPrice = 0;
   sequence.tpPrice      = 0;
   sequence.slPrice      = 0;

   // restore positions
   if (long.enabled) {
      long.openLots = 0;
      long.slippage = 0;
      long.openPL   = 0;
      long.bePrice  = 0;
      long.minLevel = INT_MAX;
      long.maxLevel = INT_MIN;
      if (!RestorePositions(long.history, longOpenPrice)) return(false);
   }
   if (short.enabled) {
      short.openLots = 0;
      short.slippage = 0;
      short.openPL   = 0;
      short.bePrice  = 0;
      short.minLevel = INT_MAX;
      short.maxLevel = INT_MIN;
      if (!RestorePositions(short.history, shortOpenPrice)) return(false);
   }

   // set the new gridbase and update open net lots
   if      (sequence.direction == D_LONG)  sequence.startPrice = longOpenPrice;
   else if (sequence.direction == D_SHORT) sequence.startPrice = shortOpenPrice;
   else                                    sequence.startPrice = (longOpenPrice + shortOpenPrice)/2;
   sequence.startPrice   = NormalizeDouble(sequence.startPrice, Digits);
   sequence.gridbase     = NormalizeDouble(oldGridbase + sequence.startPrice - oldStopPrice, Digits);
   sequence.openLots     = NormalizeDouble(long.openLots - short.openLots, 2); SS.Lots();
   sequence.avgOpenPrice = (long.openLots*longOpenPrice - short.openLots*shortOpenPrice)/sequence.openLots;

   // update pending orders
   if (!UpdatePendingOrders()) return(false);
   if (IsLogInfo()) logInfo("ResumeSequence(3)  "+ sequence.name +" sequence resumed at "+ NumberToStr(sequence.startPrice, PriceFormat) +" (new gridbase "+ NumberToStr(sequence.gridbase, PriceFormat) +")");

   ComputeProfit(true);
   ComputeTargets();
   return(SaveStatus());
}


/**
 * Restore the open positions of the last sequence cycle. Called only from ResumeSequence().
 *
 * @param  _In_  double history[][] - order history
 * @param  _Out_ double openPrice   - variable receiving the average open price of the opened positions
 *
 * @return bool - success status
 */
bool RestorePositions(double history[][], double &openPrice) {
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("RestorePositions(1)  "+ sequence.name +" cannot restore positions of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int size = ArrayRange(history, 0);
   if (!size) return(!catch("RestorePositions(2)  "+ sequence.name +" cannot restore last cycle (empty history)", ERR_ILLEGAL_STATE));

   int lastCycle = history[size-1][HI_CYCLE];
   double price=0, lots=0, sumPrice=0, sumLots=0;

   for (int i=0; i < size; i++) {
      if (history[i][HI_CYCLE] == lastCycle) {
         int direction = ifInt(history[i][HI_OPENTYPE]==OP_BUY, D_LONG, D_SHORT);

         if (!Grid.AddPosition(direction, history[i][HI_LEVEL], price, lots)) return(false);
         sumPrice += lots * price;
         sumLots  += lots;
      }
   }
   openPrice = MathDiv(sumPrice, sumLots);

   return(!catch("RestorePositions(3)"));
}


/**
 * Stop a waiting or progressing sequence. Closes open positions, deletes pending orders and stops the sequence.
 *
 * @param  int signal - signal which triggered the stop condition or NULL on explicit (i.e. manual) stop
 *
 * @return bool - success status
 */
bool StopSequence(int signal) {
   if (IsLastError())                                                          return(false);
   if (sequence.status!=STATUS_WAITING && sequence.status!=STATUS_PROGRESSING) return(!catch("StopSequence(1)  "+ sequence.name +" cannot stop "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   double hedgeOpenPrice = 0;

   if (sequence.status == STATUS_PROGRESSING) {                      // a progressing sequence has open orders to close (a waiting sequence has none)
      if (IsLogInfo()) logInfo("StopSequence(2)  "+ sequence.name +" stopping sequence...");
      int hedgeTicket, oe[];

      if (NE(sequence.openLots, 0)) {                               // hedge the total open position: execution price = sequence close price
         int      type        = ifInt(GT(sequence.openLots, 0), OP_SELL, OP_BUY);
         double   lots        = MathAbs(sequence.openLots);
         double   price       = NULL;
         int      slippage    = 10;                                  // point
         double   stopLoss    = NULL;
         double   takeProfit  = NULL;
         string   comment     = "";
         int      magicNumber = CreateMagicNumber(NULL);
         datetime expires     = NULL;
         color    markerColor = CLR_NONE;
         int      oeFlags     = NULL;
         if (!OrderSendEx(Symbol(), type, lots, price, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe)) return(!SetLastError(oe.Error(oe)));
         hedgeTicket    = oe.Ticket(oe);
         hedgeOpenPrice = oe.OpenPrice(oe);
      }

      if (!Grid.RemovePendingOrders()) return(false);                // cancel and remove all pending orders
      if (!StopSequence.ClosePositions(hedgeTicket)) return(false);  // close all open and the hedging position

      sequence.openLots     = 0;
      sequence.avgOpenPrice = 0;
      sequence.floatingPL   = 0;
      sequence.hedgedPL     = 0;
      sequence.openPL       = 0;                                     // update total PL numbers
      sequence.closedPL     = NormalizeDouble(long.closedPL + short.closedPL, 2);
      sequence.totalPL      = sequence.closedPL;
      sequence.maxProfit    = MathMax(sequence.maxProfit, sequence.totalPL);
      sequence.maxDrawdown  = MathMin(sequence.maxDrawdown, sequence.totalPL);
      SS.TotalPL(true);
      SS.PLStats(true);
   }

   sequence.status    = STATUS_STOPPED;
   sequence.stopTime  = Tick.time;
   sequence.stopPrice = doubleOr(hedgeOpenPrice, NormalizeDouble((Bid+Ask)/2, Digits));
   if (IsLogInfo()) logInfo("StopSequence(3)  "+ sequence.name +" sequence stopped at "+ NumberToStr(sequence.stopPrice, PriceFormat) +", profit: "+ sSequenceTotalPL +" "+ StrReplace(sSequencePlStats, " ", ""));

   // update stop conditions
   switch (signal) {
      case SIGNAL_PRICE_TIME:
         stop.price.condition = false;
         break;

      case SIGNAL_TAKEPROFIT:
         stop.profitAbs.condition = false;
         stop.profitPct.condition = false;
         break;

      case SIGNAL_STOPLOSS:
         stop.lossAbs.condition = false;
         stop.lossPct.condition = false;
         break;

      case NULL:                                                     // explicit (manual) stop or end of test
         break;

      default: return(!catch("StopSequence(4)  "+ sequence.name +" invalid parameter signal: "+ signal, ERR_INVALID_PARAMETER));
   }
   SS.StopConditions();
   SaveStatus();

   if (__isTesting) {                                                // pause/stop the tester according to the debug configuration
      if (!IsVisualMode())       Tester.Stop ("StopSequence(5)");
      else if (test.onStopPause) Tester.Pause("StopSequence(6)");
   }
   return(!catch("StopSequence(7)"));
}


/**
 * Close all open positions.
 *
 * @param  int hedgeTicket - ticket of the hedging close ticket or NULL if the total position was already hedged
 *
 * @return bool - success status
 */
bool StopSequence.ClosePositions(int hedgeTicket) {
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("StopSequence.ClosePositions(1)  "+ sequence.name +" cannot close open positions of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   // collect all open positions
   int lastLongPosition=-1, lastShortPosition=-1, positions[]; ArrayResize(positions, 0);

   if (long.enabled) {
      int orders = ArraySize(long.ticket);
      for (int i=0; i < orders; i++) {
         if (!long.closeTime[i] && long.openType[i]!=OP_UNDEFINED) {
            ArrayPushInt(positions, long.ticket[i]);
         }
      }
      lastLongPosition = orders - 1;
   }
   if (short.enabled) {
      orders = ArraySize(short.ticket);
      for (i=0; i < orders; i++) {
         if (!short.closeTime[i] && short.openType[i]!=OP_UNDEFINED) {
            ArrayPushInt(positions, short.ticket[i]);
         }
      }
      lastShortPosition = orders - 1;
   }
   if (hedgeTicket != NULL) ArrayPushInt(positions, hedgeTicket);

   // close open positions and update local order state
   if (ArraySize(positions) > 0) {
      int slippage = 10;    // point
      int oeFlags, oes[][ORDER_EXECUTION_intSize], pos;
      if (!OrdersClose(positions, slippage, CLR_CLOSED, oeFlags, oes)) return(!SetLastError(oes.Error(oes, 0)));

      double remainingSwap, remainingCommission, remainingProfit;
      orders = ArrayRange(oes, 0);

      for (i=0; i < orders; i++) {
         if (oes.Type(oes, i) == OP_BUY) {
            pos = SearchIntArray(long.ticket, oes.Ticket(oes, i));
            if (pos >= 0) {
               long.closeTime [pos] = oes.CloseTime (oes, i);
               long.closePrice[pos] = oes.ClosePrice(oes, i);
               long.swap      [pos] = oes.Swap      (oes, i);
               long.commission[pos] = oes.Commission(oes, i);
               long.profit    [pos] = oes.Profit    (oes, i);
               long.closedPL += long.swap[pos] + long.commission[pos] + long.profit[pos];
            }
            else {
               remainingSwap       += oes.Swap      (oes, i);
               remainingCommission += oes.Commission(oes, i);
               remainingProfit     += oes.Profit    (oes, i);
            }
         }
         else {
            pos = SearchIntArray(short.ticket, oes.Ticket(oes, i));
            if (pos >= 0) {
               short.closeTime [pos] = oes.CloseTime (oes, i);
               short.closePrice[pos] = oes.ClosePrice(oes, i);
               short.swap      [pos] = oes.Swap      (oes, i);
               short.commission[pos] = oes.Commission(oes, i);
               short.profit    [pos] = oes.Profit    (oes, i);
               short.closedPL += short.swap[pos] + short.commission[pos] + short.profit[pos];
            }
            else {
               remainingSwap       += oes.Swap      (oes, i);
               remainingCommission += oes.Commission(oes, i);
               remainingProfit     += oes.Profit    (oes, i);
            }
         }
      }

      if (lastLongPosition >= 0) {
         long.swap      [lastLongPosition] += remainingSwap;
         long.commission[lastLongPosition] += remainingCommission;
         long.profit    [lastLongPosition] += remainingProfit;
         long.closedPL += remainingSwap + remainingCommission + remainingProfit;
      }
      else {
         short.swap      [lastShortPosition] += remainingSwap;
         short.commission[lastShortPosition] += remainingCommission;
         short.profit    [lastShortPosition] += remainingProfit;
         short.closedPL += remainingSwap + remainingCommission + remainingProfit;
      }

      long.openPL    = 0;
      short.openPL   = 0;
      long.closedPL  = NormalizeDouble(long.closedPL, 2);
      short.closedPL = NormalizeDouble(short.closedPL, 2);
   }
   return(!catch("StopSequence.ClosePositions(2)"));
}


/**
 * Delete the pending orders of a sequence and remove them from the order arrays. If an order was already executed local
 * state is updated and the order is kept.
 *
 * @param bool saveStatus [optional] - whether to save the sequence status before a successful return (default: no)
 *
 * @return bool - success status
 */
bool Grid.RemovePendingOrders(bool saveStatus = false) {
   saveStatus = saveStatus!=0;
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("Grid.RemovePendingOrders(1)  "+ sequence.name +" cannot delete pending orders of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   if (long.enabled) {
      int orders = ArraySize(long.ticket), oeFlags, oe[];

      for (int i=0; i < orders; i++) {
         if (long.closeTime[i] > 0) continue;                           // skip tickets already known as closed
         if (long.openType[i] == OP_UNDEFINED) {                        // an order locally known as pending
            oeFlags = F_ERR_INVALID_TRADE_PARAMETERS;                   // accept the order already being executed

            if (OrderDeleteEx(long.ticket[i], CLR_NONE, oeFlags, oe)) {
               if (!Orders.RemoveRecord(D_LONG, i)) return(false);
               orders--;
               i--;
               continue;
            }
            if (oe.Error(oe) != ERR_INVALID_TRADE_PARAMETERS) return(false);

            // the order was already executed: update local state
            if (!SelectTicket(long.ticket[i], "Grid.RemovePendingOrders(2)")) return(false);
            long.openType  [i] = OrderType();
            long.openTime  [i] = OrderOpenTime();
            long.openPrice [i] = OrderOpenPrice();
            long.swap      [i] = OrderSwap();
            long.commission[i] = OrderCommission();
            long.profit    [i] = OrderProfit();
            if (IsLogDebug()) logDebug("Grid.RemovePendingOrders(3)  "+ sequence.name +" "+ UpdateStatus.OrderFillMsg(D_LONG, i));

            long.minLevel  = MathMin(long.level[i], long.minLevel);
            long.maxLevel  = MathMax(long.level[i], long.maxLevel);
            long.openLots += long.lots[i];
            long.slippage += oe.Slippage(oe)*Point;                     // TODO: what non-sense is this???
         }
      }
   }

   if (short.enabled) {
      orders = ArraySize(short.ticket);

      for (i=0; i < orders; i++) {
         if (short.closeTime[i] > 0) continue;                          // skip tickets already known as closed
         if (short.openType[i] == OP_UNDEFINED) {                       // an order locally known as pending
            oeFlags = F_ERR_INVALID_TRADE_PARAMETERS;                   // accept the order already being executed

            if (OrderDeleteEx(short.ticket[i], CLR_NONE, oeFlags, oe)) {
               if (!Orders.RemoveRecord(D_SHORT, i)) return(false);
               orders--;
               i--;
               continue;
            }
            if (oe.Error(oe) != ERR_INVALID_TRADE_PARAMETERS) return(false);

            // the order was already executed: update local state
            if (!SelectTicket(short.ticket[i], "Grid.RemovePendingOrders(4)")) return(false);
            short.openType  [i] = OrderType();
            short.openTime  [i] = OrderOpenTime();
            short.openPrice [i] = OrderOpenPrice();
            short.swap      [i] = OrderSwap();
            short.commission[i] = OrderCommission();
            short.profit    [i] = OrderProfit();
            if (IsLogDebug()) logDebug("Grid.RemovePendingOrders(5)  "+ sequence.name +" "+ UpdateStatus.OrderFillMsg(D_SHORT, i));

            short.minLevel  = MathMin(short.level[i], short.minLevel);
            short.maxLevel  = MathMax(short.level[i], short.maxLevel);
            short.openLots += short.lots[i];
            short.slippage += oe.Slippage(oe)*Point;                    // TODO: what non-sense is this???
         }
      }
   }

   if (saveStatus) SaveStatus();
   return(!catch("Grid.RemovePendingOrders(6)"));
}


/**
 * Update order and PL status with current market data and signal status changes.
 *
 * @param  _Out_ bool gridChanged - whether a grid parameter changed (e.g. the current grid level)
 * @param  _Out_ bool gridError   - whether an external intervention was detected (order cancellation or close)
 *
 * @return bool - success status
 */
bool UpdateStatus(bool &gridChanged, bool &gridError) {
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("UpdateStatus(1)  "+ sequence.name +" cannot update order status of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   static int prevMaxUnits = 0; if (MaxUnits != prevMaxUnits) {
      prevMaxUnits = MaxUnits;                           // detect runtime changes of MaxGridLevels
      gridChanged = true;
   }

   if (!UpdateStatus.Direction(D_LONG,  gridChanged, gridError, long.openLots,  long.slippage,  long.openPL,  long.closedPL,  long.minLevel,  long.maxLevel,  long.ticket,  long.level,  long.lots,  long.pendingType,  long.pendingPrice,  long.openType,  long.openTime,  long.openPrice,  long.closeTime,  long.closePrice,  long.swap,  long.commission,  long.profit))  return(false);
   if (!UpdateStatus.Direction(D_SHORT, gridChanged, gridError, short.openLots, short.slippage, short.openPL, short.closedPL, short.minLevel, short.maxLevel, short.ticket, short.level, short.lots, short.pendingType, short.pendingPrice, short.openType, short.openTime, short.openPrice, short.closeTime, short.closePrice, short.swap, short.commission, short.profit)) return(false);

   if (!ComputeProfit(gridChanged)) return(false);
   if (gridChanged)
      return(ComputeTargets());
   return(!catch("UpdateStatus(2)"));
}


/**
 * UpdateStatus() sub-routine. Updates order and PL status of a single trade direction.
 *
 * @param  _In_  int  direction   - trade direction
 * @param  _Out_ bool gridChanged - whether a grid parameter changed (e.g. the current grid level)
 * @param  _Out_ bool gridError   - whether an external intervention occurred (order cancellation or position close)
 * @param  ...
 *
 * @return bool - success status
 */
bool UpdateStatus.Direction(int direction, bool &gridChanged, bool &gridError, double &totalLots, double &slippage, double &openPL, double &closedPL, int &minLevel, int &maxLevel, int tickets[], int levels[], double lots[], int pendingTypes[], double pendingPrices[], int &types[], datetime &openTimes[], double &openPrices[], datetime &closeTimes[], double &closePrices[], double &swaps[], double &commissions[], double &profits[]) {
   if (direction==D_LONG  && !long.enabled)  return(true);
   if (direction==D_SHORT && !short.enabled) return(true);

   int error, orders = ArraySize(tickets);
   bool updateSlippage=false, isLogDebug=IsLogDebug();
   totalLots = 0;
   openPL    = 0;

   // update ticket status
   for (int i=0; i < orders; i++) {
      if (closeTimes[i] > 0) continue;                            // skip tickets already known as closed
      if (!SelectTicket(tickets[i], "UpdateStatus(3)")) return(false);

      bool wasPending  = (types[i] == OP_UNDEFINED);
      bool isPending   = (OrderType() > OP_SELL);
      bool wasPosition = !wasPending;
      bool isOpen      = !OrderCloseTime();
      bool isClosed    = !isOpen;

      if (wasPending) {
         if (!isPending) {                                        // the pending order was filled
            types     [i] = OrderType();
            openTimes [i] = OrderOpenTime();
            openPrices[i] = OrderOpenPrice();

            if (isLogDebug) logDebug("UpdateStatus(4)  "+ sequence.name +" "+ UpdateStatus.OrderFillMsg(direction, i));
            minLevel = MathMin(levels[i], minLevel);
            maxLevel = MathMax(levels[i], maxLevel);
            updateSlippage = true;
            wasPosition    = true;                                // mark as known open position
            gridChanged    = true;
         }
         else if (isClosed) {                                     // the order was unexpectedly cancelled
            closeTimes[i] = OrderCloseTime();
            gridError = true;
            if (IsError(UpdateStatus.onOrderChange("UpdateStatus(5)  "+ sequence.name +" "+ UpdateStatus.OrderCancelledMsg(direction, i, error), error))) return(false);
         }
      }

      if (wasPosition) {
         swaps      [i] = OrderSwap();
         commissions[i] = OrderCommission();
         profits    [i] = OrderProfit();

         if (isOpen) {                                            // update floating PL
            totalLots += lots[i];
            openPL    += swaps[i] + commissions[i] + profits[i];
         }
         else {                                                   // the position was unexpectedly closed
            closeTimes [i] = OrderCloseTime();
            closePrices[i] = OrderClosePrice();
            closedPL += swaps[i] + commissions[i] + profits[i];   // update closed PL
            gridError = true;
            if (IsError(UpdateStatus.onOrderChange("UpdateStatus(6)  "+ sequence.name +" "+ UpdateStatus.PositionCloseMsg(direction, i, error), error))) return(false);
         }
      }
   }

   // update overall slippage
   if (updateSlippage) {
      double allLots, sumSlippage;

      for (i=0; i < orders; i++) {
         if (types[i] != OP_UNDEFINED) {
            sumSlippage += lots[i] * ifDouble(direction==D_LONG, pendingPrices[i]-openPrices[i], openPrices[i]-pendingPrices[i]);
            allLots     += lots[i];                               // sum slippage and all lots
         }
      }
      slippage = sumSlippage/allLots;                             // compute overall slippage
   }

   // normalize results
   totalLots = NormalizeDouble(totalLots, 2);
   openPL    = NormalizeDouble(openPL, 2);
   closedPL  = NormalizeDouble(closedPL, 2);
   return(!catch("UpdateStatus(7)"));
}


/**
 * Compose a log message for a filled entry order.
 *
 * @param  int direction - trade direction
 * @param  int i         - order index
 *
 * @return string - log message or an empty string in case of errors
 */
string UpdateStatus.OrderFillMsg(int direction, int i) {
   // #1 Stop Sell 0.1 GBPUSD at 1.5457'2 ("L.8692.+3") was filled[ at 1.5457'2] ([slippage: -0.3 pip, ]market: Bid/Ask)
   int ticket, level, pendingType;
   double lots, pendingPrice, openPrice;

   if (direction == D_LONG) {
      ticket       = long.ticket      [i];
      level        = long.level       [i];
      lots         = long.lots        [i];
      pendingType  = long.pendingType [i];
      pendingPrice = long.pendingPrice[i];
      openPrice    = long.openPrice   [i];
   }
   else if (direction == D_SHORT) {
      ticket       = short.ticket      [i];
      level        = short.level       [i];
      lots         = short.lots        [i];
      pendingType  = short.pendingType [i];
      pendingPrice = short.pendingPrice[i];
      openPrice    = short.openPrice   [i];
   }
   else return(_EMPTY_STR(catch("UpdateStatus.OrderFillMsg(1)  invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER)));

   string sType         = OperationTypeDescription(pendingType);
   string sPendingPrice = NumberToStr(pendingPrice, PriceFormat);
   string comment       = ifString(direction==D_LONG, "L.", "S.") + sequence.id +"."+ NumberToStr(level, "+.");
   string message       = "#"+ ticket +" "+ sType +" "+ NumberToStr(lots, ".+") +" "+ Symbol() +" at "+ sPendingPrice +" (\""+ comment +"\") was filled";

   string sSlippage = "";
   if (NE(openPrice, pendingPrice, Digits)) {
      double slippage = NormalizeDouble((pendingPrice-openPrice)/Pip, 1); if (direction == D_SHORT) slippage = -slippage;
      sSlippage = "slippage: "+ NumberToStr(slippage, "+."+ (Digits & 1)) +" pip, ";
      message = message +" at "+ NumberToStr(openPrice, PriceFormat);
   }
   return(message +" ("+ sSlippage +"market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
}


/**
 * Compose a log message for a cancelled pending entry order.
 *
 * @param  _In_  int direction - trade direction
 * @param  _In_  int i         - order index
 * @param  _Out_ int error     - error code to be attached to the log message (if any)
 *
 * @return string - log message or an empty string in case of errors
 */
string UpdateStatus.OrderCancelledMsg(int direction, int i, int &error) {
   // #1 Stop Sell 0.1 GBPUSD at 1.5457'2 ("L.8692.+3") was unexpectedly cancelled
   // #1 Stop Sell 0.1 GBPUSD at 1.5457'2 ("L.8692.+3") was deleted (not enough money)
   error = NO_ERROR;
   int ticket, level, pendingType;
   double lots, pendingPrice;

   if (direction == D_LONG) {
      ticket       = long.ticket      [i];
      level        = long.level       [i];
      lots         = long.lots        [i];
      pendingType  = long.pendingType [i];
      pendingPrice = long.pendingPrice[i];
   }
   else if (direction == D_SHORT) {
      ticket       = short.ticket      [i];
      level        = short.level       [i];
      lots         = short.lots        [i];
      pendingType  = short.pendingType [i];
      pendingPrice = short.pendingPrice[i];
   }
   else return(_EMPTY_STR(catch("UpdateStatus.OrderCancelledMsg(1)  invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER)));

   string sType         = OperationTypeDescription(pendingType);
   string sPendingPrice = NumberToStr(pendingPrice, PriceFormat);
   string comment       = ifString(direction==D_LONG, "L.", "S.") + sequence.id +"."+ NumberToStr(level, "+.");
   string message       = "#"+ ticket +" "+ sType +" "+ NumberToStr(lots, ".+") +" "+ Symbol() +" at "+ sPendingPrice +" (\""+ comment +"\") was ";
   string sReason       = "cancelled";

   SelectTicket(ticket, "UpdateStatus.OrderCancelledMsg(2)", /*push=*/true);
   sReason = "unexpectedly cancelled";
   if (OrderComment() == "deleted [no money]") {
      sReason = "deleted (not enough money)";
      error = ERR_NOT_ENOUGH_MONEY;
   }
   else if (!__isTesting || __CoreFunction!=CF_DEINIT) {
      error = ERR_CONCURRENT_MODIFICATION;
   }
   OrderPop("UpdateStatus.OrderCancelledMsg(3)");

   return(message + sReason);
}


/**
 * Compose a log message for a closed open position.
 *
 * @param  _In_  int direction - trade direction
 * @param  _In_  int i         - order index
 * @param  _Out_ int error     - error code to be attached to the log message (if any)
 *
 * @return string - log message or an empty string in case of errors
 */
string UpdateStatus.PositionCloseMsg(int direction, int i, int &error) {
   // #1 Sell 0.1 GBPUSD at 1.5457'2 ("L.8692.+3") was unexpectedly closed at 1.5457'2 (market: Bid/Ask[, so: 47.7%/169.20/354.40])
   error = NO_ERROR;
   int ticket, level, type;
   double lots, openPrice, closePrice;

   if (direction == D_LONG) {
      ticket       = long.ticket    [i];
      level        = long.level     [i];
      type         = long.openType  [i];
      lots         = long.lots      [i];
      openPrice    = long.openPrice [i];
      closePrice   = long.closePrice[i];
   }
   else if (direction == D_SHORT) {
      ticket       = short.ticket    [i];
      level        = short.level     [i];
      type         = short.openType  [i];
      lots         = short.lots      [i];
      openPrice    = short.openPrice [i];
      closePrice   = short.closePrice[i];
   }
   else return(_EMPTY_STR(catch("UpdateStatus.PositionCloseMsg(1)  invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER)));

   string sType       = OperationTypeDescription(type);
   string sOpenPrice  = NumberToStr(openPrice, PriceFormat);
   string sClosePrice = NumberToStr(closePrice, PriceFormat);
   string comment     = ifString(direction==D_LONG, "L.", "S.") + sequence.id +"."+ NumberToStr(level, "+.");
   string message     = "#"+ ticket +" "+ sType +" "+ NumberToStr(lots, ".+") +" "+ Symbol() +" at "+ sOpenPrice +" (\""+ comment +"\") was unexpectedly closed at "+ sClosePrice;
   string sStopout    = "";

   SelectTicket(ticket, "UpdateStatus.PositionCloseMsg(2)", /*push=*/true);
   if (StrStartsWithI(OrderComment(), "so:")) {
      sStopout = ", "+ OrderComment();
      error = ERR_MARGIN_STOPOUT;
   }
   else if (!__isTesting || __CoreFunction!=CF_DEINIT) {
      error = ERR_CONCURRENT_MODIFICATION;
   }
   OrderPop("UpdateStatus.PositionCloseMsg(3)");

   return(message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) + sStopout +")");
}


/**
 * Error handler for unexpected order modifications.
 *
 * @param  string message - error message
 * @param  int    error   - error code
 *
 * @return int - the same error
 */
int UpdateStatus.onOrderChange(string message, int error) {
   if (!__isTesting) logError(message, error);
   else if (!error)  logDebug(message, error);
   else              catch(message, error);
   return(error);
}


/**
 * Check existing pending orders and add new or missing ones.
 *
 * @param bool saveStatus [optional] - whether to save the sequence status before a successful return (default: no)
 *
 * @return bool - success status
 */
bool UpdatePendingOrders(bool saveStatus = false) {
   saveStatus = saveStatus!=0;
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("UpdatePendingOrders(1)  "+ sequence.name +" cannot update orders of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   bool gridChanged = false;

   // Scaling down
   //  - limit orders: TODO: If market moves too fast positions for missed levels must be opened immediately at the better price.
   // Scaling up
   //  - stop orders:  Regular slippage is not an issue. At worst the whole grid moves by the average slippage amount which is tiny.
   //  - limit orders: Slippage on price spikes affects only a signle stop order (the next one). For all skipped levels limit orders will be placed (no slippage).
   int orders, plusLevels, minusLevels;

   if (long.enabled) {
      orders = ArraySize(long.ticket);
      if (!orders) return(!catch("UpdatePendingOrders(2)  "+ sequence.name +" illegal size of long orders: 0", ERR_ILLEGAL_STATE));

      plusLevels  = Max(0, long.maxLevel);
      minusLevels = -Min(0, long.minLevel);
      if (plusLevels && minusLevels) minusLevels--;
      if (plusLevels+minusLevels >= MaxUnits) {
         if (IsLogInfo()) {
            logInfo("UpdatePendingOrders(3)  "+ sequence.name +" max. number of long units reached ("+ MaxUnits +")");
            if (!__isTesting) PlaySoundEx("MarginLow.wav");
         }
         return(Grid.RemovePendingOrders(saveStatus));
      }

      if (sequence.pyramidEnabled) {                           // on Pyramid ensure the next stop order for scaling up exists
         if (long.level[orders-1] == long.maxLevel) {
            if (!Grid.AddPendingOrder(D_LONG, Max(long.maxLevel+1, 2))) return(false);
            if (IsLimitOrderType(long.pendingType[orders])) {  // handle a missed sequence level
               long.maxLevel = long.level[orders];
               gridChanged = true;
            }
            orders++;
         }
      }
      if (sequence.martingaleEnabled) {                        // on Martingale ensure the next limit order for scaling down exists
         if (long.level[0] == long.minLevel) {
            if (!Grid.AddPendingOrder(D_LONG, Min(long.minLevel-1, -2))) return(false);
            if (IsStopOrderType(long.pendingType[0])) {        // handle a missed sequence level
               long.minLevel = long.level[0];
               gridChanged = true;
            }
            orders++;
         }
      }
   }

   if (short.enabled) {
      orders = ArraySize(short.ticket);
      if (!orders) return(!catch("UpdatePendingOrders(4)  "+ sequence.name +" illegal size of short orders: 0", ERR_ILLEGAL_STATE));

      plusLevels  = Max(0, short.maxLevel);
      minusLevels = -Min(0, short.minLevel);
      if (plusLevels && minusLevels) minusLevels--;
      if (plusLevels+minusLevels >= MaxUnits) {
         if (IsLogInfo()) {
            logInfo("UpdatePendingOrders(5)  "+ sequence.name +" max. number of short units reached ("+ MaxUnits +")");
            if (!__isTesting) PlaySoundEx("MarginLow.wav");
         }
         return(Grid.RemovePendingOrders(saveStatus));
      }

      if (sequence.pyramidEnabled) {                           // on Pyramid ensure the next stop order for scaling up exists
         if (short.level[orders-1] == short.maxLevel) {
            if (!Grid.AddPendingOrder(D_SHORT, Max(short.maxLevel+1, 2))) return(false);
            if (IsLimitOrderType(short.pendingType[orders])) { // handle a missed sequence level
               short.maxLevel = short.level[orders];
               gridChanged = true;
            }
            orders++;
         }
      }
      if (sequence.martingaleEnabled) {                        // on Martingale ensure the next limit order for scaling down exists
         if (short.level[0] == short.minLevel) {
            if (!Grid.AddPendingOrder(D_SHORT, Min(short.minLevel-1, -2))) return(false);
            if (IsStopOrderType(short.pendingType[0])) {       // handle a missed sequence level
               short.minLevel = short.level[0];
               gridChanged = true;
            }
            orders++;
         }
      }
   }

   if (gridChanged) UpdatePendingOrders(false);                // call the function again if some levels have been missed
   if (saveStatus)  SaveStatus();

   return(!catch("UpdatePendingOrders(6)"));
}


/**
 * Generate a new sequence id. Must be unique for all instances of this expert (strategy).
 *
 * @return int - sequence id in the range from 1000-9999
 */
int CreateSequenceId() {
   MathSrand(GetTickCount()-__ExecutionContext[EC.hChartWindow]);
   int id;
   while (id < SID_MIN || id > SID_MAX) {
      id = MathRand();                                         // TODO: in tester generate consecutive ids
   }                                                           // TODO: test id for uniqueness
   return(id);
}


/**
 * Return a unique symbol for the sequence. Called from core/expert/init_Recorder() if recordCustom is TRUE.
 *
 * @return string - unique symbol or an empty string in case of errors
 */
//string GetUniqueSymbol() {
//   if (!sequence.id) return(!catch("GetUniqueSymbol(1)  "+ sequence.name +" illegal sequence id: "+ sequence.id, ERR_ILLEGAL_STATE));
//   return("Duel_"+ sequence.id);
//}


/**
 * Generate a unique magic order number for the sequence.
 *
 * @param  int level - gridlevel
 *
 * @return int - magic number or NULL in case of errors
 */
int CreateMagicNumber(int level) {
   if (STRATEGY_ID < 101 || STRATEGY_ID > 1023)  return(!catch("CreateMagicNumber(1)  "+ sequence.name +" illegal strategy id: "+ STRATEGY_ID, ERR_ILLEGAL_STATE));
   if (sequence.id < 1000 || sequence.id > 9999) return(!catch("CreateMagicNumber(2)  "+ sequence.name +" illegal sequence id: "+ sequence.id, ERR_ILLEGAL_STATE));

   int strategy = STRATEGY_ID;                                 //  101-1023 (10 bit)
   int sequence = sequence.id;                                 // 1000-9999 (14 bit)
   int _level   = level;                                       //     0-255 (8 bit)
   return((strategy<<22) + (sequence<<8) + (_level<<0));
}


/**
 * Calculate the price of a gridlevel of the specified direction.
 *
 * @param  int    direction           - trade direction
 * @param  int    level               - gridlevel
 * @param  double gridbase [optional] - gridbase to use (default: the current gridbase)
 *
 * @return double - gridlevel price or NULL in case of errors
 */
double CalculateGridLevel(int direction, int level, double gridbase = NULL) {
   if (IsLastError())               return(NULL);
   if (!level || level==-1)         return(!catch("CalculateGridLevel(1)  "+ sequence.name +" invalid parameter level: "+ level, ERR_INVALID_PARAMETER));
   if (!gridbase) {
      if (sequence.gridbase < 0.01) return(!catch("CalculateGridLevel(2)  "+ sequence.name +" illegal value of sequence.gridbase: "+ NumberToStr(sequence.gridbase, ".1+"), ERR_ILLEGAL_STATE));
      gridbase = sequence.gridbase;
   }
   else if (gridbase < 0.01)        return(!catch("CalculateGridLevel(3)  "+ sequence.name +" invalid parameter gridbase: "+ NumberToStr(gridbase, ".1+"), ERR_INVALID_PARAMETER));
   if (sequence.gridsize < 0.01)    return(!catch("CalculateGridLevel(4)  "+ sequence.name +" illegal value of sequence.gridsize: "+ NumberToStr(sequence.gridsize, ".+"), ERR_ILLEGAL_STATE));

   double price = 0;

   if (direction == D_LONG) {
      if (level > 0) price = gridbase + (level-1) * sequence.gridsize*Pip;
      else           price = gridbase + (level+1) * sequence.gridsize*Pip;
   }
   else if (direction == D_SHORT) {
      if (level > 0) price = gridbase - (level-1) * sequence.gridsize*Pip;
      else           price = gridbase - (level+1) * sequence.gridsize*Pip;
   }
   else return(!catch("CalculateGridLevel(5)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));

   return(NormalizeDouble(price, Digits));
}


/**
 * Calculate the order volume to use for the specified trade direction and grid level.
 *
 * @param  int direction - trade direction
 * @param  int level     - gridlevel
 *
 * @return double - normalized order volume or NULL in case of errors
 */
double CalculateLots(int direction, int level) {
   if (IsLastError())                                   return(NULL);
   if      (direction == D_LONG)  { if (!long.enabled)  return(NULL); }
   else if (direction == D_SHORT) { if (!short.enabled) return(NULL); }
   else                                                 return(!catch("CalculateLots(1)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));
   if (!level)                                          return(!catch("CalculateLots(2)  "+ sequence.name +" invalid parameter level: "+ level, ERR_INVALID_PARAMETER));
   if (sequence.unitsize < 0.005)                       return(!catch("CalculateLots(3)  "+ sequence.name +" illegal value of sequence.unitsize: "+ NumberToStr(sequence.unitsize, ".1+"), ERR_ILLEGAL_STATE));

   double lots = 0;

   if (Abs(level) == 1) {             // covers +1 and -1
      lots = sequence.unitsize;
   }
   else if (level > 0) {              // pyramid levels
      if (sequence.pyramidEnabled)    lots = sequence.unitsize * MathPow(Pyramid.Multiplier, level-1);
   }
   else {                             // martingale levels
      if (sequence.martingaleEnabled) lots = sequence.unitsize * MathPow(Martingale.Multiplier, -level-1);
   }
   lots = NormalizeLots(lots); if (IsEmptyValue(lots)) return(NULL);

   return(ifDouble(catch("CalculateLots(4)"), NULL, lots));
}


/**
 * Compute and update the PL values of the sequence.
 *
 * @param  bool gridChanged - whether a grid property changed since the last call (to signal cache invalidation)
 *
 * @return bool - success status
 */
bool ComputeProfit(bool gridChanged) {
   gridChanged = gridChanged!=0;

   if (gridChanged) {
      sequence.openLots = NormalizeDouble(long.openLots - short.openLots, 2); SS.Lots();
   }
   sequence.avgOpenPrice       = 0;
   sequence.floatingCommission = 0;
   sequence.floatingSwap       = 0;
   sequence.floatingPL         = 0;
   sequence.hedgedPL           = 0;
   sequence.closedPL           = long.closedPL + short.closedPL;

   int longOrders=ArraySize(long.ticket), shortOrders=ArraySize(short.ticket), orders=longOrders + shortOrders;

   int    tickets    []; ArrayResize(tickets,     orders);
   int    types      []; ArrayResize(types,       orders);
   double lots       []; ArrayResize(lots,        orders);
   double openPrices []; ArrayResize(openPrices,  orders);
   double commissions[]; ArrayResize(commissions, orders);
   double swaps      []; ArrayResize(swaps,       orders);
   double profits    []; ArrayResize(profits,     orders);

   // copy open positions to temp. arrays (ararys are modified in the process)
   for (int n, i=0; i < longOrders; i++) {
      if (long.openType[i]!=OP_UNDEFINED && !long.closeTime[i]) {
         tickets    [n] = long.ticket    [i];
         types      [n] = long.openType  [i];
         lots       [n] = long.lots      [i];
         openPrices [n] = long.openPrice [i];
         commissions[n] = long.commission[i];
         swaps      [n] = long.swap      [i];
         profits    [n] = long.profit    [i];
         n++;
      }
   }
   for (i=0; i < shortOrders; i++) {
      if (short.openType[i]!=OP_UNDEFINED && !short.closeTime[i]) {
         tickets    [n] = short.ticket    [i];
         types      [n] = short.openType  [i];
         lots       [n] = short.lots      [i];
         openPrices [n] = short.openPrice [i];
         commissions[n] = short.commission[i];
         swaps      [n] = short.swap      [i];
         profits    [n] = short.profit    [i];
         n++;
      }
   }
   if (n < orders) {
      ArrayResize(tickets,     n);
      ArrayResize(types,       n);
      ArrayResize(lots,        n);
      ArrayResize(openPrices,  n);
      ArrayResize(commissions, n);
      ArrayResize(swaps,       n);
      ArrayResize(profits,     n);
      orders = n;
   }

   // compute openPL = floatingPL + hedgedPL
   double hedgedLots, remainingLong, remainingShort, factor, sumOpenPrice, sumClosePrice, sumCommission, sumSwap, floatingPL, pipValue, pipDistance;

   // compute PL of a hedged part
   if (long.openLots && short.openLots) {
      hedgedLots     = MathMin(long.openLots, short.openLots);
      remainingLong  = hedgedLots;
      remainingShort = hedgedLots;

      for (i=0; i < orders; i++) {
         if (!tickets[i]) continue;

         if (types[i] == OP_BUY) {
            if (!remainingLong) continue;
            if (remainingLong >= lots[i]) {
               // apply all data except profit; afterwards nullify the ticket
               sumOpenPrice  += lots[i] * openPrices[i];
               sumSwap       += swaps[i];
               sumCommission += commissions[i];
               remainingLong = NormalizeDouble(remainingLong - lots[i], 3);
               tickets[i]    = NULL;
            }
            else {
               // apply all swap and partial commission; afterwards reduce the ticket's commission, profit and lotsize
               factor         = remainingLong/lots[i];
               sumOpenPrice  += remainingLong * openPrices[i];
               sumSwap       += swaps[i];                swaps      [i]  = 0;
               sumCommission += factor * commissions[i]; commissions[i] -= factor * commissions[i];
                                                         profits    [i] -= factor * profits    [i];
                                                         lots       [i]  = NormalizeDouble(lots[i]-remainingLong, 3);
               remainingLong = 0;
            }
         }
         else /*types[i] == OP_SELL*/ {
            if (!remainingShort) continue;
            if (remainingShort >= lots[i]) {
               // apply all swap; afterwards nullify the ticket
               sumClosePrice += lots[i] * openPrices[i];
               sumSwap       += swaps[i];                                              // commission is applied only at the long leg
               remainingShort = NormalizeDouble(remainingShort - lots[i], 3);
               tickets[i]     = NULL;
            }
            else {
               // apply all swap; afterwards reduce the ticket's commission, profit and lotsize
               factor         = remainingShort/lots[i];
               sumClosePrice += remainingShort * openPrices[i];
               sumSwap       += swaps[i]; swaps      [i]  = 0;
                                          commissions[i] -= factor * commissions[i];   // commission is applied only at the long leg
                                          profits    [i] -= factor * profits    [i];
                                          lots       [i]  = NormalizeDouble(lots[i]-remainingShort, 3);
               remainingShort = 0;
            }
         }
      }
      if (remainingLong!=0 || remainingShort!=0) return(!catch("ComputeProfit(1)  illegal remaining "+ ifString(!remainingShort, "long", "short") +" position "+ NumberToStr(remainingLong, ".+") +" of hedged position = "+ NumberToStr(hedgedLots, ".+"), ERR_RUNTIME_ERROR));

      // calculate profit from the difference openPrice-closePrice
      pipValue          = PipValue(hedgedLots); if (!pipValue) return(false);
      pipDistance       = (sumClosePrice - sumOpenPrice)/hedgedLots/Pip + (sumCommission + sumSwap)/pipValue;
      sequence.hedgedPL = pipDistance * pipValue;
      sumOpenPrice      = 0;
      sumCommission     = 0;
      sumSwap           = 0;
   }

   // compute PL of a floating long position
   if (sequence.openLots > 0) {
      remainingLong = sequence.openLots;
      sumOpenPrice  = 0;
      sumCommission = 0;
      sumSwap       = 0;
      floatingPL    = 0;

      for (i=0; i < orders; i++) {
         if (!tickets[i]   ) continue;
         if (!remainingLong) break;

         if (types[i] == OP_BUY) {
            if (remainingLong >= lots[i]) {
               // apply all data
               sumOpenPrice  += lots[i] * openPrices[i];
               sumSwap       += swaps[i];
               sumCommission += commissions[i];
               floatingPL    += profits[i];
               remainingLong  = NormalizeDouble(remainingLong - lots[i], 3);
            }
            else {
               // apply all swap, partial commission, partial profit; afterwards reduce the ticket's commission, profit and lotsize
               factor         = remainingLong/lots[i];
               sumOpenPrice  += remainingLong * openPrices[i];
               sumSwap       +=          swaps      [i]; swaps      [i]  = 0;
               sumCommission += factor * commissions[i]; commissions[i] -= factor * commissions[i];
               floatingPL    += factor * profits    [i]; profits    [i] -= factor * profits    [i];
                                                         lots       [i]  = NormalizeDouble(lots[i]-remainingLong, 3);
               remainingLong = 0;
            }
         }
      }
      if (remainingLong != 0) return(!catch("ComputeProfit(2)  illegal remaining long position "+ NumberToStr(remainingLong, ".+") +" of open position = "+ NumberToStr(sequence.openLots, ".+"), ERR_RUNTIME_ERROR));

      sequence.avgOpenPrice       = sumOpenPrice/sequence.openLots;
      sequence.floatingCommission = sumCommission;
      sequence.floatingSwap       = sumSwap;
      sequence.floatingPL         = floatingPL + sumCommission + sumSwap;
   }

   // compute PL of a floating short position
   if (sequence.openLots < 0) {
      remainingShort = -sequence.openLots;
      sumOpenPrice   = 0;
      sumCommission  = 0;
      sumSwap        = 0;
      floatingPL     = 0;

      for (i=0; i < orders; i++) {
         if (!tickets[i]    ) continue;
         if (!remainingShort) break;

         if (types[i] == OP_SELL) {
            if (remainingShort >= lots[i]) {
               // apply all data
               sumOpenPrice  += lots[i] * openPrices[i];
               sumSwap       += swaps[i];
               sumCommission += commissions[i];
               floatingPL    += profits[i];
               remainingShort = NormalizeDouble(remainingShort - lots[i], 3);
            }
            else {
               // apply all swap, partial commission, partial profit; afterwards reduce the ticket's commission, profit and lotsize
               factor         = remainingShort/lots[i];
               sumOpenPrice  += remainingShort * openPrices[i];
               sumSwap       +=          swaps[i];       swaps      [i]  = 0;
               sumCommission += factor * commissions[i]; commissions[i] -= factor * commissions[i];
               floatingPL    += factor * profits[i];     profits    [i] -= factor * profits    [i];
                                                         lots       [i]  = NormalizeDouble(lots[i]-remainingShort, 3);
               remainingShort = 0;
            }
         }
      }
      if (remainingShort != 0) return(!catch("ComputeProfit(3)  illegal remaining short position "+ NumberToStr(remainingShort, ".+") +" of open position = "+ NumberToStr(sequence.openLots, ".+"), ERR_RUNTIME_ERROR));

      sequence.avgOpenPrice       = -sumOpenPrice/sequence.openLots;
      sequence.floatingCommission = sumCommission;
      sequence.floatingSwap       = sumSwap;
      sequence.floatingPL         = floatingPL + sumCommission + sumSwap;
   }

   // summarize and process results
   sequence.openPL   = NormalizeDouble(sequence.floatingPL + sequence.hedgedPL, 2);
   sequence.closedPL = NormalizeDouble(sequence.closedPL, 2);
   sequence.totalPL  = NormalizeDouble(sequence.openPL + sequence.closedPL, 2);
   SS.TotalPL();

   if      (sequence.totalPL > sequence.maxProfit  ) { sequence.maxProfit   = sequence.totalPL; SS.PLStats(); }
   else if (sequence.totalPL < sequence.maxDrawdown) { sequence.maxDrawdown = sequence.totalPL; SS.PLStats(); }

   return(!catch("ComputeProfit(4)"));
}


/**
 * Compute and update the PL targets of the sequence.
 *
 * @return bool - success status
 */
bool ComputeTargets() {
   double lots, avgPrice, commission, swap, hedgedPL, closedPL, targetPL, gridbase;
   int gridlevel;

   if (long.enabled) {
      long.bePrice     = NULL;
      sequence.tpPrice = NULL;
      sequence.slPrice = NULL;

      lots       = sequence.openLots;
      avgPrice   = sequence.avgOpenPrice;
      commission = sequence.floatingCommission;
      swap       = sequence.floatingSwap;
      hedgedPL   = sequence.hedgedPL;
      closedPL   = sequence.closedPL;
      gridlevel  = Max(long.maxLevel, 0);

      if (sequence.status == STATUS_PROGRESSING) gridbase = sequence.gridbase;
      else if (sequence.direction == D_LONG)     gridbase = Ask;
      else                                       gridbase = NormalizeDouble((Bid+Ask)/2, Digits);

      // extrapolate to a net long position (if not already the case)
      if (lots <  0) ExtrapolateShort2HedgedOrLong(lots, avgPrice, commission, swap, hedgedPL, gridlevel, gridbase);
      if (lots == 0) ExtrapolateHedged2Long(lots, avgPrice, commission, gridlevel, gridbase);

      // calculate breakeven
      targetPL = 0;
      long.bePrice = ComputeTarget(D_LONG, targetPL, lots, avgPrice, commission, swap, hedgedPL, closedPL, gridlevel, gridbase); if (!long.bePrice) return(false);

      // calculate takeprofit
      if (stop.profitAbs.condition)      targetPL = stop.profitAbs.value;
      else if (stop.profitPct.condition) targetPL = stop.profitPct.AbsValue();
      else                               targetPL = INT_MAX;
      if (targetPL != INT_MAX) {
         sequence.tpPrice = ComputeTarget(D_LONG, targetPL, lots, avgPrice, commission, swap, hedgedPL, closedPL, gridlevel, gridbase); if (!sequence.tpPrice) return(false);
      }

      // calculate stoploss                                                      // TODO: calculation is wrong
      //if (stop.lossAbs.condition)      targetPL = stop.lossAbs.value;
      //else if (stop.lossPct.condition) targetPL = stop.lossPct.AbsValue();
      //else                             targetPL = INT_MIN;
      //if (targetPL != INT_MIN) {
      //   sequence.slPrice = ComputeTarget(D_LONG, targetPL, lots, avgPrice, commission, swap, hedgedPL, closedPL, gridlevel, gridbase); if (!sequence.slPrice) return(false);
      //}
   }

   if (short.enabled) {
      short.bePrice    = NULL;
      sequence.tpPrice = NULL;
      sequence.slPrice = NULL;

      lots       = sequence.openLots;
      avgPrice   = sequence.avgOpenPrice;
      commission = sequence.floatingCommission;
      swap       = sequence.floatingSwap;
      hedgedPL   = sequence.hedgedPL;
      closedPL   = sequence.closedPL;
      gridlevel  = Max(short.maxLevel, 0);

      if (sequence.status == STATUS_PROGRESSING) gridbase = sequence.gridbase;
      else if (sequence.direction == D_SHORT)    gridbase = Bid;
      else                                       gridbase = NormalizeDouble((Bid+Ask)/2, Digits);

      // extrapolate to a net short position (if not already the case)
      if (lots >  0) ExtrapolateLong2HedgedOrShort(lots, avgPrice, commission, swap, hedgedPL, gridlevel, gridbase);
      if (lots == 0) ExtrapolateHedged2Short(lots, avgPrice, commission, gridlevel, gridbase);

      // calculate breakeven
      targetPL = 0;
      short.bePrice = ComputeTarget(D_SHORT, targetPL, lots, avgPrice, commission, swap, hedgedPL, closedPL, gridlevel, gridbase); if (!short.bePrice) return(false);

      // calculate takeprofit
      if (stop.profitAbs.condition)      targetPL = stop.profitAbs.value;
      else if (stop.profitPct.condition) targetPL = stop.profitPct.AbsValue();
      else                               targetPL = INT_MAX;
      if (targetPL != INT_MAX) {
         sequence.tpPrice = ComputeTarget(D_SHORT, targetPL, lots, avgPrice, commission, swap, hedgedPL, closedPL, gridlevel, gridbase); if (!sequence.tpPrice) return(false);
      }

      // calculate stoploss                                                      // TODO: calculation is wrong
      //if (stop.lossAbs.condition)      targetPL = stop.lossAbs.value;
      //else if (stop.lossPct.condition) targetPL = stop.lossPct.AbsValue();
      //else                             targetPL = INT_MIN;
      //if (targetPL != INT_MIN) {
      //   sequence.slPrice = ComputeTarget(D_SHORT, targetPL, lots, avgPrice, commission, swap, hedgedPL, closedPL, gridlevel, gridbase); if (!sequence.slPrice) return(false);
      //}
   }

   if (__isChart) {
      // also store results in the chart window (for target indicator)
      SetWindowDoubleA(__ExecutionContext[EC.hChart], "Duel.breakeven.long",   long.bePrice);
      SetWindowDoubleA(__ExecutionContext[EC.hChart], "Duel.breakeven.short", short.bePrice);
      SetWindowDoubleA(__ExecutionContext[EC.hChart], "Duel.takeprofit",   sequence.tpPrice);
      SetWindowDoubleA(__ExecutionContext[EC.hChart], "Duel.stoploss",     sequence.slPrice);
   }
   SS.Targets();

   return(!catch("ComputeTargets(1)"));
}


/**
 * Extrapolate a hedged to a net long position.
 *
 * @param  _Out_   double lots       - resulting long position
 * @param  _Out_   double price      - open price of the resulting position
 * @param  _Out_   double commission - open commission of the resulting position
 * @param  _InOut_ int    gridlevel  - gridlevel of the given/resulting position
 * @param  _In_    double gridbase   - gridbase of the position
 *
 * @return bool - success status
 */
bool ExtrapolateHedged2Long(double &lots, double &price, double &commission, int &gridlevel, double gridbase) {
   gridlevel++;
   lots       = CalculateLots(D_LONG, gridlevel);                if (!lots)  return(false);
   price      = CalculateGridLevel(D_LONG, gridlevel, gridbase); if (!price) return(false);
   commission = -RoundCeil(GetCommission(lots), 2);
   return(true);
}


/**
 * Extrapolate a hedged to a net short position.
 *
 * @param  _Out_   double lots       - resulting short position
 * @param  _Out_   double price      - open price of the resulting position
 * @param  _Out_   double commission - open commission of the resulting position
 * @param  _InOut_ int    gridlevel  - gridlevel of the given/resulting position
 * @param  _In_    double gridbase   - gridbase of the position
 *
 * @return bool - success status
 */
bool ExtrapolateHedged2Short(double &lots, double &price, double &commission, int &gridlevel, double gridbase) {
   gridlevel++;
   lots       = -CalculateLots(D_SHORT, gridlevel);               if (!lots)  return(false);
   price      = CalculateGridLevel(D_SHORT, gridlevel, gridbase); if (!price) return(false);
   commission = RoundCeil(GetCommission(lots), 2);
   return(true);
}


/**
 * Extrapolate a net long position to hedged or net short.
 *
 * @param  _InOut_ double lots       - given/resulting position
 * @param  _InOut_ double avgPrice   - average open price of the given/resulting position
 * @param  _InOut_ double commission - commissions of the given/resulting position (without hedged parts)
 * @param  _InOut_ double swap       - swaps of the given/resulting position (without hedged parts)
 * @param  _InOut_ double hedgedPL   - given/resulting PL of hedged parts/positions
 * @param  _InOut_ int    gridlevel  - gridlevel of the given/resulting position
 * @param  _In_    double gridbase   - gridbase of the position
 *
 * @return bool - success status
 */
bool ExtrapolateLong2HedgedOrShort(double &lots, double &avgPrice, double &commission, double &swap, double &hedgedPL, int &gridlevel, double gridbase) {
   double sumPrices=lots*avgPrice, nextPrice, nextLots, pipValuePerLot=PipValue();

   while (lots > 0) {
      gridlevel++;
      nextPrice  = CalculateGridLevel(D_SHORT, gridlevel, gridbase); if (!nextPrice) return(false);
      nextLots   = CalculateLots(D_SHORT, gridlevel);                if (!nextLots)  return(false);
      lots       = NormalizeDouble(lots - nextLots, 2);
      sumPrices -= nextLots*nextPrice;
      avgPrice   = MathDiv(sumPrices, lots);
      hedgedPL  += (nextPrice-avgPrice)/Pip * (nextLots+MathMin(0, lots)) * pipValuePerLot;
   }

   hedgedPL  += commission + swap;
   commission = RoundCeil(GetCommission(lots), 2);
   swap       = 0;
   return(true);
}


/**
 * Extrapolate a net short position to hedged or net long.
 *
 * @param  _InOut_ double lots       - given/resulting position
 * @param  _InOut_ double avgPrice   - average open price of the given/resulting position
 * @param  _InOut_ double commission - commissions of the given/resulting position (without hedged parts)
 * @param  _InOut_ double swap       - swaps of the given/resulting position (without hedged parts)
 * @param  _InOut_ double hedgedPL   - given/resulting PL of hedged parts/positions
 * @param  _InOut_ int    gridlevel  - gridlevel of the given/resulting position
 * @param  _In_    double gridbase   - gridbase of the position
 *
 * @return bool - success status
 */
bool ExtrapolateShort2HedgedOrLong(double &lots, double &avgPrice, double &commission, double &swap, double &hedgedPL, int &gridlevel, double gridbase) {
   double sumPrices=lots*avgPrice, nextPrice, nextLots, pipValuePerLot=PipValue();

   while (lots < 0) {
      gridlevel++;
      nextPrice  = CalculateGridLevel(D_LONG, gridlevel, gridbase); if (!nextPrice) return(false);
      nextLots   = CalculateLots(D_LONG, gridlevel);                if (!nextLots)  return(false);
      lots       = NormalizeDouble(lots + nextLots, 2);
      sumPrices += nextLots*nextPrice;
      avgPrice   = MathDiv(sumPrices, lots);
      hedgedPL  += (avgPrice-nextPrice)/Pip * (nextLots-MathMax(0, lots)) * pipValuePerLot;
   }

   hedgedPL  += commission + swap;
   commission = -RoundCeil(GetCommission(lots), 2);
   swap       = 0;
   return(true);
}


/**
 * Compute the price a position reaches the defined profit target considering future grid positions.
 *
 * @param  int    direction  - direction of grid positions: D_LONG | D_SHORT
 * @param  double targetPL   - profit target in account currency to reach
 * @param  double lots       - open net position:                                      -n...+n
 * @param  double avgPrice   - average price of the open position
 * @param  double commission - commission of the open position (without hedged parts): -n...0
 * @param  double swap       - swap of the open position (without hedged parts):       -n...0
 * @param  double hedgedPL   - PL of hedged parts/positions:                           -n...+n
 * @param  double closedPL   - PL of already closed positions:                         -n...+n
 * @param  int    gridlevel  - gridlevel of the position
 * @param  double gridbase   - gridbase of the position
 *
 * @return double - price level reaching the defined target or NULL in case of errors
 */
double ComputeTarget(int direction, double targetPL, double lots, double avgPrice, double commission, double swap, double hedgedPL, double closedPL, int gridlevel, double gridbase) {
   int nextLevel;
   double nextLots, nextPrice, sumPrices, targetPrice, pipValue, pipValuePerLot=PipValue(), commissionPerLot=GetCommission();
   if (!pipValuePerLot || IsEmpty(commissionPerLot)) return(NULL);

   // long
   if (direction == D_LONG) {
      if (lots <= 0) return(!catch("ComputeTarget(1)  not a net long position: lots="+ NumberToStr(lots, ".1+"), ERR_RUNTIME_ERROR));

      sumPrices   = lots * avgPrice;
      pipValue    = lots * pipValuePerLot;
      targetPrice = avgPrice - (closedPL + hedgedPL + commission + swap - targetPL)/pipValue*Pip;           // target price using the current gridlevel
      nextLevel   = gridlevel + 1;
      nextPrice   = CalculateGridLevel(D_LONG, nextLevel, gridbase); if (!nextPrice) return(false);         // price of the next gridlevel

      while (nextPrice < targetPrice) {
         nextLots    = CalculateLots(D_LONG, nextLevel); if (!nextLots) return(false);
         lots       += nextLots;
         sumPrices  += nextLots * nextPrice;
         commission -= RoundCeil(nextLots * commissionPerLot, 2);
         pipValue    = lots * pipValuePerLot;
         targetPrice = sumPrices/lots - (closedPL + hedgedPL + commission + swap - targetPL)/pipValue*Pip;  // target price using the next gridlevel
         nextLevel++;
         nextPrice = CalculateGridLevel(D_LONG, nextLevel, gridbase); if (!nextPrice) return(false);        // price of the next gridlevel
      }
      return(targetPrice);
   }

   // short
   if (direction == D_SHORT) {
      if (lots >= 0) return(!catch("ComputeTarget(2)  not a net short position: lots="+ NumberToStr(lots, ".1+"), ERR_RUNTIME_ERROR));

      sumPrices   = -lots * avgPrice;
      pipValue    = -lots * pipValuePerLot;
      targetPrice = avgPrice + (closedPL + hedgedPL + commission + swap - targetPL)/pipValue*Pip;           // target price using the current gridlevel
      nextLevel   = gridlevel + 1;
      nextPrice   = CalculateGridLevel(D_SHORT, nextLevel, gridbase); if (!nextPrice) return(false);        // price of the next gridlevel

      while (nextPrice > targetPrice) {
         nextLots    = CalculateLots(D_SHORT, nextLevel); if (!nextLots) return(false);
         lots       -= nextLots;
         sumPrices  += nextLots * nextPrice;
         commission -= RoundCeil(nextLots * commissionPerLot, 2);
         pipValue    = -lots * pipValuePerLot;
         targetPrice = (closedPL + hedgedPL + commission + swap - targetPL)/pipValue*Pip - sumPrices/lots;  // target price using the next gridlevel
         nextLevel++;
         nextPrice = CalculateGridLevel(D_SHORT, nextLevel, gridbase); if (!nextPrice) return(false);       // price of the next gridlevel
      }
      return(targetPrice);
   }

   return(!catch("ComputeTarget(3)  invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));
}


/**
 * Auto-configure and set missing grid parameters. If all 3 parameters are set gridsize and unitsize override the specified
 * volatility.
 *
 * @param  _InOut_ double &gridvola - the specified/resulting grid volatility
 * @param  _InOut_ double &gridsize - the specified/resulting gridsize
 * @param  _InOut_ double &unitsize - the specified/resulting unitsize
 *
 * @return bool - success status
 */
bool ConfigureGrid(double &gridvola, double &gridsize, double &unitsize) {
   if (IsLastError())      return(false);
   bool sequenceWasStarted = (ArraySize(long.ticket) || ArraySize(short.ticket));
   if (sequenceWasStarted) return(true);                             // skip reconfiguration after sequence start

   if (LT(gridvola, 0) || LT(gridsize, 0) || LT(unitsize, 0)) return(!catch("ConfigureGrid(1)  "+ sequence.name +" invalid parameters GridVolatility="+ NumberToStr(gridvola, ".+") +" / GridSize="+ NumberToStr(gridsize, ".+") +" / UnitSize="+ NumberToStr(unitsize, ".+") +" (all must be non-negative)", ERR_INVALID_PARAMETER));
   if (!gridvola && (!gridsize || !unitsize))                 return(!catch("ConfigureGrid(2)  "+ sequence.name +" insufficient parameters GridVolatility="+ NumberToStr(gridvola, ".+") +" / GridSize="+ NumberToStr(gridsize, ".+") +" / UnitSize="+ NumberToStr(unitsize, ".+"), ERR_INVALID_PARAMETER));

   double adr        = GetADR();                                                if (!adr)       return(false);
   double tickSize   = MarketInfo(Symbol(), MODE_TICKSIZE);                     if (!tickSize)  return(!catch("ConfigureGrid(4)  "+ sequence.name +" MODE_TICKSIZE=0", ERR_RUNTIME_ERROR));
   double tickValue  = MarketInfo(Symbol(), MODE_TICKVALUE);                    if (!tickValue) return(!catch("ConfigureGrid(5)  "+ sequence.name +" MODE_TICKVALUE=0", ERR_RUNTIME_ERROR));
   double equity     = AccountEquity() - AccountCredit() + GetExternalAssets(); if (!equity)    return(!catch("ConfigureGrid(6)  "+ sequence.name +" equity=0", ERR_RUNTIME_ERROR));
   double beDistance = adr/2, adrLevels, adrLots, pl;

   if (gridsize && unitsize) {
      // calculate the resulting volatility
      adrLevels = adr/Pip/gridsize + 1;
      adrLots   = unitsize * adrLevels;
      pl        = beDistance/tickSize * tickValue * adrLots;
      gridvola  = pl/equity * 100;

      if (!gridvola) return(!catch("ConfigureGrid(7)  "+ sequence.name +" gridsize="+ PipToStr(gridsize) +"  unitsize="+ NumberToStr(unitsize, ".+") +"  => resulting gridvola: 0", ERR_RUNTIME_ERROR));
                          logDebug("ConfigureGrid(8)  "+ sequence.name +" adr="+ PipToStr(adr/Pip) +"  gridsize="+ PipToStr(gridsize) +"  unitsize="+ NumberToStr(unitsize, ".+") +"  gridvola="+ DoubleToStr(gridvola, 1) +"%");
      if (gridvola > 150) logNotice("ConfigureGrid(9)  "+ sequence.name +" The resulting grid volatility is larger than 150%: "+ DoubleToStr(gridvola, 1) +"%");
      return(!catch("ConfigureGrid(10)"));
   }
   else if (gridvola && unitsize) {
      // calculate the resulting gridsize
      pl        = gridvola/100 * equity;
      adrLots   = pl/beDistance/tickValue * tickSize;
      adrLevels = adrLots/unitsize;
      gridsize  = MathDiv(adr/Pip, adrLevels-1);
      gridsize  = RoundCeil(gridsize, Digits & 1);                   // round gridsize up
      if (gridsize < 0) logError("ConfigureGrid(11)  illegal result: pl="+ DoubleToStr(pl, 2) +"  adr="+ NumberToStr(adr, ".+") +"  adrLots="+ NumberToStr(adrLots, ".+") +"  adrLevels="+ NumberToStr(adrLevels, ".+") +" => resulting gridsize: "+ NumberToStr(gridsize, ".+"), ERR_RUNTIME_ERROR);
      if (!gridsize) return(!catch("ConfigureGrid(12)  "+ sequence.name +" gridvola="+ NumberToStr(gridvola, ".+") +"  unitsize="+ NumberToStr(unitsize, ".+") +"  => resulting gridsize: 0", ERR_RUNTIME_ERROR));
   }
   else if (gridvola && gridsize) {
      // calculate the resulting unitsize
      pl        = gridvola/100 * equity;
      adrLevels = adr/Pip/gridsize + 1;
      adrLots   = pl/beDistance/tickValue * tickSize;
      unitsize  = adrLots/adrLevels;
      unitsize  = NormalizeLots(unitsize, NULL, MODE_FLOOR);         // round unitsize down
      if (!unitsize) return(false);
   }
   else /*gridvola*/{
      gridsize = adr/Pip/20;                                         // calculate estimated gridsize
      gridsize = RoundCeil(gridsize, Digits & 1);                    // round gridsize up

      if (ConfigureGrid(gridvola, gridsize, unitsize))               // calculate unitsize from estimated gridsize
         return(true);
      if (IsLastError()) return(false);
      if (!unitsize) {
         gridsize = 0;
         unitsize = MarketInfo(Symbol(), MODE_MINLOT);               // set unitsize to the minimum
      }
   }
   return(ConfigureGrid(gridvola, gridsize, unitsize));              // recalculate missings after adjusted or rounded up/down values
}


/**
 * Return the full name of the instance logfile.
 *
 * @return string - filename or an empty string in case of errors
 */
string GetLogFilename() {
   string name = GetStatusFilename();
   if (!StringLen(name)) return("");
   return(StrLeftTo(name, ".", -1) +".log");
}


/**
 * Return the full name of the instance status file.
 *
 * @param  bool relative [optional] - whether to return the absolute path or the path relative to the MQL "files" directory
 *                                    (default: the absolute path)
 *
 * @return string - filename or an empty string in case of errors
 */
string GetStatusFilename(bool relative = false) {
   relative = relative!=0;
   if (!sequence.id) return(_EMPTY_STR(catch("GetStatusFilename(1)  "+ sequence.name +" illegal value of sequence.id: "+ sequence.id, ERR_ILLEGAL_STATE)));

   static string filename = ""; if (!StringLen(filename)) {
      string directory = "presets/"+ ifString(IsTestSequence(), "Tester", GetAccountCompanyId()) +"/";
      string baseName  = StrToLower(Symbol()) +".Duel."+ sequence.id +".set";
      filename = directory + baseName;
   }

   if (relative)
      return(filename);
   return(GetMqlSandboxPath() +"/"+ filename);
}


/**
 * Open a market position for the specified grid level and add the order data to the order arrays. There is no check whether
 * the specified grid level matches the current market price.
 *
 * @param  _In_  int    direction - trade direction: D_LONG | D_SHORT
 * @param  _In_  int    level     - grid level of the position to open: -n...-1 | +1...+n
 * @param  _Out_ double openPrice - variable receiving the open price of the position
 * @param  _Out_ double lots      - variable receiving the opened lotsize
 *
 * @return bool - success status
 */
int Grid.AddPosition(int direction, int level, double &openPrice, double &lots) {
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("Grid.AddPosition(1)  "+ sequence.name +" cannot add position to "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int oe[];
   int ticket = SubmitMarketOrder(direction, level, oe);
   if (!ticket) return(false);

   // prepare dataset
   //int    ticket       = ...                                                   // use as is
   //int    level        = ...                                                   // ...
            lots         = oe.Lots(oe);
   int      pendingType  = OP_UNDEFINED;
   datetime pendingTime  = NULL;
   double   pendingPrice = ifDouble(direction==D_LONG, oe.Ask(oe), oe.Bid(oe));  // for tracking of slippage
   int      openType     = oe.Type(oe);
   datetime openTime     = oe.OpenTime(oe);
            openPrice    = oe.OpenPrice(oe);
   datetime closeTime    = NULL;
   double   closePrice   = NULL;
   double   swap         = oe.Swap(oe);
   double   commission   = oe.Commission(oe);
   double   profit       = NULL;

   if (Orders.AddRecord(direction, ticket, level, lots, pendingType, pendingTime, pendingPrice, openType, openTime, openPrice, closeTime, closePrice, swap, commission, profit) < 0)
      return(false);

   if (direction == D_LONG) {
      long.openLots += lots;
      long.minLevel  = MathMin(level, long.minLevel);
      long.maxLevel  = MathMax(level, long.maxLevel);
   }
   else {
      short.openLots += lots;
      short.minLevel  = MathMin(level, short.minLevel);
      short.maxLevel  = MathMax(level, short.maxLevel);
   }
   return(true);
}


/**
 * Open a pending order for the specified grid level and add the order to the order arrays. Depending on the market a stop or
 * limit order will be opened.
 *
 * @param  int direction - trade direction: D_LONG | D_SHORT
 * @param  int level     - grid level of the order to open: -n...-1 | +1...+n
 *
 * @return bool - success status
 */
bool Grid.AddPendingOrder(int direction, int level) {
   if (IsLastError())                         return(false);
   if (sequence.status != STATUS_PROGRESSING) return(!catch("Grid.AddPendingOrder(1)  "+ sequence.name +" cannot add pending order to "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   int type = ifInt(level > 0, OA_STOP, OA_LIMIT), ticket, oe[], counter;

   // loop until an order was opened or an unexpected error occurred
   while (true) {
      if (type == OA_STOP) ticket = SubmitStopOrder(direction, level, oe);
      else                 ticket = SubmitLimitOrder(direction, level, oe);
      if (ticket > 0) break;

      int error = oe.Error(oe);
      if (error != ERR_INVALID_STOP) return(false);

      counter++; if (counter > 9) return(!catch("Grid.AddPendingOrder(2)  "+ sequence.name +" stopping trade request loop after "+ counter +" unsuccessful tries, last error", error));
      if (IsLogDebug()) logDebug("Grid.AddPendingOrder(3)  "+ sequence.name +" illegal price "+ OperationTypeDescription(oe.Type(oe)) +" at "+ NumberToStr(oe.OpenPrice(oe), PriceFormat) +" (market: "+ NumberToStr(oe.Bid(oe), PriceFormat) +"/"+ NumberToStr(oe.Ask(oe), PriceFormat) +"), opening "+ ifString(IsStopOrderType(oe.Type(oe)), "limit", "stop") +" order instead...");
      type = ifInt(type==OA_LIMIT, OA_STOP, OA_LIMIT);
   }

   // prepare dataset
   //int    ticket       = ...                                    // use as is
   //int    level        = ...                                    // ...
   double   lots         = oe.Lots(oe);
   int      pendingType  = oe.Type(oe);
   datetime pendingTime  = oe.OpenTime(oe);
   double   pendingPrice = oe.OpenPrice(oe);
   int      openType     = OP_UNDEFINED;
   datetime openTime     = NULL;
   double   openPrice    = NULL;
   datetime closeTime    = NULL;
   double   closePrice   = NULL;
   double   swap         = NULL;
   double   commission   = NULL;
   double   profit       = NULL;

   return(!IsEmpty(Orders.AddRecord(direction, ticket, level, lots, pendingType, pendingTime, pendingPrice, openType, openTime, openPrice, closeTime, closePrice, swap, commission, profit)));
}


/**
 * Whether the current sequence was created in the tester. Considers that a test sequence can be loaded into an online
 * chart after the test (for visualization).
 *
 * @return bool
 */
bool IsTestSequence() {
   return(sequence.isTest || __isTesting);
}


// backed-up input parameters
string   prev.Sequence.ID = "";
string   prev.GridDirection = "";
string   prev.GridVolatility = "";
string   prev.GridVolatilityRange = "";
string   prev.GridSize = "";
double   prev.UnitSize;
int      prev.MaxUnits;
double   prev.Pyramid.Multiplier;
double   prev.Martingale.Multiplier;
string   prev.StopConditions = "";
bool     prev.ShowProfitInPercent;
datetime prev.Sessionbreak.StartTime;
datetime prev.Sessionbreak.EndTime;
string   prev.EA.Recorder = "";

// backed-up runtime variables affected by changing input parameters
int      prev.sequence.id;
datetime prev.sequence.created;
bool     prev.sequence.isTest;
string   prev.sequence.name = "";
int      prev.sequence.cycle;
int      prev.sequence.status;
int      prev.sequence.direction;
bool     prev.sequence.pyramidEnabled;
bool     prev.sequence.martingaleEnabled;
double   prev.sequence.gridsize;
double   prev.sequence.unitsize;
double   prev.sequence.gridvola;

bool     prev.long.enabled;
bool     prev.short.enabled;

bool     prev.stop.price.condition;
int      prev.stop.price.type;
double   prev.stop.price.value;
double   prev.stop.price.lastValue;
string   prev.stop.price.description = "";
bool     prev.stop.profitAbs.condition;
double   prev.stop.profitAbs.value;
string   prev.stop.profitAbs.description = "";
bool     prev.stop.profitPct.condition;
double   prev.stop.profitPct.value;
double   prev.stop.profitPct.absValue;
string   prev.stop.profitPct.description = "";
bool     prev.stop.lossAbs.condition;
double   prev.stop.lossAbs.value;
string   prev.stop.lossAbs.description = "";
bool     prev.stop.lossPct.condition;
double   prev.stop.lossPct.value;
double   prev.stop.lossPct.absValue;
string   prev.stop.lossPct.description = "";

datetime prev.sessionbreak.starttime;
datetime prev.sessionbreak.endtime;

int      prev.recordMode;
bool     prev.recordInternal;
bool     prev.recordCustom;


/**
 * Programatically changed input parameters don't survive init cycles. Therefore inputs are backed-up in deinit() and can be
 * restored in init(). Called in onDeinitParameters() and onDeinitChartChange().
 */
void BackupInputs() {
   // backup input parameters, also accessed for comparison in ValidateInputs()
   prev.Sequence.ID            = StringConcatenate(Sequence.ID, "");       // string inputs are references to internal C literals...
   prev.GridDirection          = StringConcatenate(GridDirection, "");     // ...and must be copied to break the reference
   prev.GridVolatility         = StringConcatenate(GridVolatility, "");
   prev.GridSize               = StringConcatenate(GridSize, "");
   prev.UnitSize               = UnitSize;
   prev.MaxUnits               = MaxUnits;
   prev.Pyramid.Multiplier     = Pyramid.Multiplier;
   prev.Martingale.Multiplier  = Martingale.Multiplier;
   prev.StopConditions         = StringConcatenate(StopConditions, "");
   prev.ShowProfitInPercent    = ShowProfitInPercent;
   prev.Sessionbreak.StartTime = Sessionbreak.StartTime;
   prev.Sessionbreak.EndTime   = Sessionbreak.EndTime;
   prev.EA.Recorder            = StringConcatenate(EA.Recorder, "");

   // backup runtime variables affected by changing input parameters
   prev.sequence.id                = sequence.id;
   prev.sequence.created           = sequence.created;
   prev.sequence.isTest            = sequence.isTest;
   prev.sequence.name              = sequence.name;
   prev.sequence.cycle             = sequence.cycle;
   prev.sequence.status            = sequence.status;
   prev.sequence.direction         = sequence.direction;
   prev.sequence.pyramidEnabled    = sequence.pyramidEnabled;
   prev.sequence.martingaleEnabled = sequence.martingaleEnabled;
   prev.sequence.gridsize          = sequence.gridsize;
   prev.sequence.unitsize          = sequence.unitsize;
   prev.sequence.gridvola          = sequence.gridvola;

   prev.long.enabled               = long.enabled ;
   prev.short.enabled              = short.enabled;

   prev.stop.price.condition       = stop.price.condition;
   prev.stop.price.type            = stop.price.type;
   prev.stop.price.value           = stop.price.value;
   prev.stop.price.lastValue       = stop.price.lastValue;
   prev.stop.price.description     = stop.price.description;
   prev.stop.profitAbs.condition   = stop.profitAbs.condition;
   prev.stop.profitAbs.value       = stop.profitAbs.value;
   prev.stop.profitAbs.description = stop.profitAbs.description;
   prev.stop.profitPct.condition   = stop.profitPct.condition;
   prev.stop.profitPct.value       = stop.profitPct.value;
   prev.stop.profitPct.absValue    = stop.profitPct.absValue;
   prev.stop.profitPct.description = stop.profitPct.description;
   prev.stop.lossAbs.condition     = stop.lossAbs.condition;
   prev.stop.lossAbs.value         = stop.lossAbs.value;
   prev.stop.lossAbs.description   = stop.lossAbs.description;
   prev.stop.lossPct.condition     = stop.lossPct.condition;
   prev.stop.lossPct.value         = stop.lossPct.value;
   prev.stop.lossPct.absValue      = stop.lossPct.absValue;
   prev.stop.lossPct.description   = stop.lossPct.description;

   prev.sessionbreak.starttime     = sessionbreak.starttime;
   prev.sessionbreak.endtime       = sessionbreak.endtime;

   prev.recordMode                 = recordMode;
   prev.recordInternal             = recordInternal;
   prev.recordCustom               = recordCustom;
}


/**
 * Restore backed-up input parameters and global vars. Called from onInitParameters() and onInitTimeframeChange().
 */
void RestoreInputs() {
   // restore input parameters
   Sequence.ID            = prev.Sequence.ID;
   GridDirection          = prev.GridDirection;
   GridVolatility         = prev.GridVolatility;
   GridSize               = prev.GridSize;
   UnitSize               = prev.UnitSize;
   MaxUnits               = prev.MaxUnits;
   Pyramid.Multiplier     = prev.Pyramid.Multiplier;
   Martingale.Multiplier  = prev.Martingale.Multiplier;
   StopConditions         = prev.StopConditions;
   ShowProfitInPercent    = prev.ShowProfitInPercent;
   Sessionbreak.StartTime = prev.Sessionbreak.StartTime;
   Sessionbreak.EndTime   = prev.Sessionbreak.EndTime;
   EA.Recorder            = prev.EA.Recorder;

   // restore runtime variables
   sequence.id                = prev.sequence.id;
   sequence.created           = prev.sequence.created;
   sequence.isTest            = prev.sequence.isTest;
   sequence.name              = prev.sequence.name;
   sequence.cycle             = prev.sequence.cycle;
   sequence.status            = prev.sequence.status;
   sequence.direction         = prev.sequence.direction;
   sequence.pyramidEnabled    = prev.sequence.pyramidEnabled;
   sequence.martingaleEnabled = prev.sequence.martingaleEnabled;
   sequence.gridsize          = prev.sequence.gridsize;
   sequence.unitsize          = prev.sequence.unitsize;
   sequence.gridvola          = prev.sequence.gridvola;

   long.enabled               = prev.long.enabled ;
   short.enabled              = prev.short.enabled;

   stop.price.condition       = prev.stop.price.condition;
   stop.price.type            = prev.stop.price.type;
   stop.price.value           = prev.stop.price.value;
   stop.price.lastValue       = prev.stop.price.lastValue;
   stop.price.description     = prev.stop.price.description;
   stop.profitAbs.condition   = prev.stop.profitAbs.condition;
   stop.profitAbs.value       = prev.stop.profitAbs.value;
   stop.profitAbs.description = prev.stop.profitAbs.description;
   stop.profitPct.condition   = prev.stop.profitPct.condition;
   stop.profitPct.value       = prev.stop.profitPct.value;
   stop.profitPct.absValue    = prev.stop.profitPct.absValue;
   stop.profitPct.description = prev.stop.profitPct.description;
   stop.lossAbs.condition     = prev.stop.lossAbs.condition;
   stop.lossAbs.value         = prev.stop.lossAbs.value;
   stop.lossAbs.description   = prev.stop.lossAbs.description;
   stop.lossPct.condition     = prev.stop.lossPct.condition;
   stop.lossPct.value         = prev.stop.lossPct.value;
   stop.lossPct.absValue      = prev.stop.lossPct.absValue;
   stop.lossPct.description   = prev.stop.lossPct.description;

   sessionbreak.starttime     = prev.sessionbreak.starttime;
   sessionbreak.endtime       = prev.sessionbreak.endtime;

   recordMode                 = prev.recordMode;
   recordInternal             = prev.recordInternal;
   recordCustom               = prev.recordCustom;
}


/**
 * Validate and apply the input parameter "Sequence.ID".
 *
 * @return bool - whether a sequence id was successfully restored (the status file is not checked)
 */
bool ValidateInputs.SID() {
   bool errorFlag = true;

   if (!ApplySequenceId(Sequence.ID, errorFlag, "ValidateInputs.SID(1)")) {
      if (errorFlag) onInputError("ValidateInputs.SID(2)  invalid input parameter Sequence.ID: \""+ Sequence.ID +"\"");
      return(false);
   }
   return(true);
}


/**
 * Validate the input parameters. Parameters may have been entered through the input dialog, read from a status file or
 * deserialized and applied programmatically by the terminal (e.g. at terminal restart). Called from onInitUser(),
 * onInitParameters() or onInitTemplate().
 *
 * @return bool - whether input parameters are valid
 */
bool ValidateInputs() {
   if (IsLastError()) return(false);
   bool isInitParameters   = (ProgramInitReason()==IR_PARAMETERS);      // whether we validate manual or programatic input
   bool isInitUser         = (ProgramInitReason()==IR_USER);
   bool isInitTemplate     = (ProgramInitReason()==IR_TEMPLATE);
   bool sequenceWasStarted = (ArraySize(long.ticket) || ArraySize(short.ticket));

   // Sequence.ID
   if (isInitParameters) {
      string sValues[], sValue = StrTrim(Sequence.ID);
      if (sValue == "") {                                                // the id was deleted or not yet set, re-apply the internal id
         Sequence.ID = prev.Sequence.ID;
      }
      else if (sValue != prev.Sequence.ID)                               return(!onInputError("ValidateInputs(1)  "+ sequence.name +" switching to another sequence is not supported (unload the EA first)"));
   } //else                                                              // the id was validated in ValidateInputs.SID()

   // GridDirection
   sValue = GridDirection;
   if (Explode(sValue, "*", sValues, 2) > 1) {
      int size = Explode(sValues[0], "|", sValues, NULL);
      sValue = sValues[size-1];
   }
   sValue = StrTrim(sValue);
   int iValue = StrToTradeDirection(sValue, F_PARTIAL_ID|F_ERR_INVALID_PARAMETER);
   if (iValue == -1)                                                     return(!onInputError("ValidateInputs(2)  "+ sequence.name +" invalid parameter GridDirection: "+ DoubleQuoteStr(GridDirection)));
   if (isInitParameters && iValue!=prev.sequence.direction) {
      if (sequenceWasStarted)                                            return(!onInputError("ValidateInputs(3)  "+ sequence.name +" cannot change parameter GridDirection of already started sequence"));
   }
   sequence.direction = iValue;
   long.enabled  = (sequence.direction & D_LONG  && 1);
   short.enabled = (sequence.direction & D_SHORT && 1);
   GridDirection = TradeDirectionDescription(sequence.direction);

   // GridVolatility
   if (isInitParameters && !StrCompareI(GridVolatility, prev.GridVolatility)) {
      if (sequenceWasStarted)                                            return(!onInputError("ValidateInputs(4)  "+ sequence.name +" cannot change parameter GridVolatility of already started sequence"));
   }
   sValue = StrTrim(GridVolatility);
   if (!StringLen(sValue) || sValue=="{percent}") {
      GridVolatility = "";
      if (!sequenceWasStarted) sequence.gridvola = 0;
   }
   else {
      if (StrEndsWith(sValue, "%"))
         sValue = StrTrim(StrLeft(sValue, -1));
      if (!StrIsNumeric(sValue))                                         return(!onInputError("ValidateInputs(5)  "+ sequence.name +" invalid parameter GridVolatility: "+ DoubleQuoteStr(GridVolatility) +" (not numeric)"));
      double dValue = MathAbs(StrToDouble(sValue));
      GridVolatility = NumberToStr(dValue, ".+") +"%";
      if (!sequenceWasStarted) sequence.gridvola = dValue;
   }

   // GridSize
   if (isInitParameters && !StrCompare(GridSize, prev.GridSize)) {
      if (sequenceWasStarted)                                            return(!onInputError("ValidateInputs(6)  "+ sequence.name +" cannot change parameter GridSize of already started sequence"));
   }
   sValue = StrTrim(GridSize);
   dValue = 0;
   if (sValue != "") {
      if (!StrIsNumeric(sValue))                                         return(!onInputError("ValidateInputs(7)  "+ sequence.name +" invalid parameter GridSize: "+ DoubleQuoteStr(GridSize) +" (not numeric)"));
      dValue = StrToDouble(sValue);
      if (LT(dValue, 0))                                                 return(!onInputError("ValidateInputs(8)  "+ sequence.name +" invalid parameter GridSize: "+ DoubleQuoteStr(GridSize) +" (too small)"));
      int digits = StringLen(StrRightFrom(sValue, "."));                 // interpret input as a currency amount or a pip value
      if (Close[0]>=500 && Digits==2 && digits==2) dValue = NormalizeDouble(dValue * 100, 0);
      else if (MathModFix(dValue*Pip, Point) != 0)                       return(!onInputError("ValidateInputs(9)  "+ sequence.name +" invalid parameter GridSize: "+ DoubleQuoteStr(GridSize) +" (not a multiple of Point)"));
   }
   if (!sequenceWasStarted) sequence.gridsize = dValue;

   // UnitSize
   if (isInitParameters && NE(UnitSize, prev.UnitSize)) {
      if (sequenceWasStarted)                                            return(!onInputError("ValidateInputs(10)  "+ sequence.name +" cannot change parameter UnitSize of already started sequence"));
   }
   if (LT(UnitSize, 0))                                                  return(!onInputError("ValidateInputs(11)  "+ sequence.name +" invalid parameter UnitSize: "+ NumberToStr(UnitSize, ".1+") +" (too small)"));
   if (NE(UnitSize, NormalizeLots(UnitSize)))                            return(!onInputError("ValidateInputs(12)  "+ sequence.name +" invalid parameter UnitSize: "+ NumberToStr(UnitSize, ".1+") +" (not a multiple of MODE_LOTSTEP="+ NumberToStr(MarketInfo(Symbol(), MODE_LOTSTEP), ".+") +")"));
   if (!sequenceWasStarted) sequence.unitsize = UnitSize;
   if (!sequence.gridvola && (!sequence.gridsize || !sequence.unitsize)) return(!onInputError("ValidateInputs(13)  "+ sequence.name +" missing some parameters GridVolatility=0 / GridSize="+ NumberToStr(sequence.gridsize, ".+") +" / UnitSize="+ NumberToStr(sequence.unitsize, ".+")));
   // MaxUnits
   if (MaxUnits < 1)                                                     return(!onInputError("ValidateInputs(14)  "+ sequence.name +" invalid parameter MaxUnits: "+ MaxUnits));

   // Pyramid.Multiplier
   if (isInitParameters && NE(Pyramid.Multiplier, prev.Pyramid.Multiplier)) {
      if (sequenceWasStarted)                                            return(!onInputError("ValidateInputs(15)  "+ sequence.name +" cannot change parameter Pyramid.Multiplier of already started sequence"));
   }
   if (Pyramid.Multiplier < 0)                                           return(!onInputError("ValidateInputs(16)  "+ sequence.name +" invalid parameter Pyramid.Multiplier: "+ NumberToStr(Pyramid.Multiplier, ".1+")));
   sequence.pyramidEnabled = (Pyramid.Multiplier > 0);

   // Martingale.Multiplier
   if (isInitParameters && NE(Martingale.Multiplier, prev.Martingale.Multiplier)) {
      if (sequenceWasStarted)                                            return(!onInputError("ValidateInputs(17)  "+ sequence.name +" cannot change parameter Martingale.Multiplier of already started sequence"));
   }
   if (Martingale.Multiplier < 0)                                        return(!onInputError("ValidateInputs(18)  "+ sequence.name +" invalid parameter Martingale.Multiplier: "+ NumberToStr(Martingale.Multiplier, ".1+")));
   sequence.martingaleEnabled = (Martingale.Multiplier > 0);

   // StopConditions, "OR" combined: @[bid|ask|price](double) | @[profit|loss](double[%])
   // -----------------------------------------------------------------------------------
   if (!isInitParameters || StopConditions!=prev.StopConditions) {       // on initParameters conditions are re-enabled on change only
      stop.price.condition     = false;
      stop.profitAbs.condition = false;
      stop.profitPct.condition = false;
      stop.lossAbs.condition   = false;
      stop.lossPct.condition   = false;

      string exprs[], expr="", key="";
      int sizeOfExprs = Explode(StrTrim(StopConditions), "|", exprs, NULL);

      // split conditions and parse/validate each expression
      for (int i=0; i < sizeOfExprs; i++) {
         expr = StrTrim(exprs[i]);
         if (!StringLen(expr))              continue;
         if (StringGetChar(expr, 0) == '!') continue;                    // skip disabled conditions
         if (StringGetChar(expr, 0) != '@')                              return(!onInputError("ValidateInputs(19)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions)));

         if (Explode(expr, "(", sValues, NULL) != 2)                     return(!onInputError("ValidateInputs(20)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions)));
         if (!StrEndsWith(sValues[1], ")"))                              return(!onInputError("ValidateInputs(21)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions)));
         key = StrTrim(sValues[0]);
         sValue = StrTrim(StrLeft(sValues[1], -1));
         if (!StringLen(sValue))                                         return(!onInputError("ValidateInputs(22)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions)));

         if (key=="@bid" || key=="@ask" || key=="@price") {
            if (stop.price.condition)                                    return(!onInputError("ValidateInputs(23)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions) +" (multiple price conditions)"));
            sValue = StrReplace(sValue, "'", "");
            if (!StrIsNumeric(sValue))                                   return(!onInputError("ValidateInputs(24)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions) +" (illegal price)"));
            dValue = StrToDouble(sValue);
            if (dValue <= 0)                                             return(!onInputError("ValidateInputs(25)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions) +" (illegal price)"));
            stop.price.value     = NormalizeDouble(dValue, Digits);
            stop.price.lastValue = NULL;
            if      (key == "@bid") stop.price.type = PRICE_BID;
            else if (key == "@ask") stop.price.type = PRICE_ASK;
            else                    stop.price.type = PRICE_MEDIAN;
            expr = NumberToStr(stop.price.value, PriceFormat);
            if (StrEndsWith(expr, "'0")) expr = StrLeft(expr, -2);       // cut "'0" for improved readability
            stop.price.description = StrSubstr(key, 1) +"("+ expr +")";
            stop.price.condition   = true;
         }

         else if (key == "@profit") {
            if (stop.profitAbs.condition || stop.profitPct.condition)    return(!onInputError("ValidateInputs(26)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions) +" (multiple profit conditions)"));
            int sizeOfElems = Explode(sValue, "%", sValues, NULL);
            if (sizeOfElems > 2)                                         return(!onInputError("ValidateInputs(27)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions)));
            sValue = StrTrim(sValues[0]);
            if (!StrIsNumeric(sValue))                                   return(!onInputError("ValidateInputs(28)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions)));
            dValue = StrToDouble(sValue);
            if (sizeOfElems == 1) {
               stop.profitAbs.value       = NormalizeDouble(dValue, 2);
               stop.profitAbs.description = "profit("+ DoubleToStr(dValue, 2) +")";
               stop.profitAbs.condition   = true;
               stop.profitPct.description = "";
            }
            else {
               stop.profitPct.value       = dValue;
               stop.profitPct.absValue    = INT_MAX;
               stop.profitPct.description = "profit("+ NumberToStr(dValue, ".+") +"%)";
               stop.profitPct.condition   = true;
               stop.profitAbs.description = "";
            }
         }

         else if (key == "@loss") {
            if (stop.lossAbs.condition || stop.lossPct.condition)        return(!onInputError("ValidateInputs(29)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions) +" (multiple loss conditions)"));
            sizeOfElems = Explode(sValue, "%", sValues, NULL);
            if (sizeOfElems > 2)                                         return(!onInputError("ValidateInputs(30)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions)));
            sValue = StrTrim(sValues[0]);
            if (!StrIsNumeric(sValue))                                   return(!onInputError("ValidateInputs(31)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions)));
            dValue = StrToDouble(sValue);
            if (sizeOfElems == 1) {
               stop.lossAbs.value       = NormalizeDouble(dValue, 2);
               stop.lossAbs.description = "loss("+ DoubleToStr(dValue, 2) +")";
               stop.lossAbs.condition   = true;
               stop.lossPct.description = "";
            }
            else {
               stop.lossPct.value       = dValue;
               stop.lossPct.absValue    = INT_MIN;
               stop.lossPct.description = "loss("+ NumberToStr(dValue, ".+") +"%)";
               stop.lossPct.condition   = true;
               stop.lossAbs.description = "";
            }
         }
         else                                                            return(!onInputError("ValidateInputs(32)  "+ sequence.name +" invalid parameter StopConditions: "+ DoubleQuoteStr(StopConditions) +" (unknown condition key)"));
      }
   }

   // Sessionbreak.StartTime/EndTime
   if (Sessionbreak.StartTime!=prev.Sessionbreak.StartTime || Sessionbreak.EndTime!=prev.Sessionbreak.EndTime) {
      sessionbreak.starttime = NULL;                                     // actual times are updated automatically on next use
      sessionbreak.endtime   = NULL;
   }

   // EA.Recorder
   int metrics;
   if (!init_RecorderValidateInput(metrics))                             return(false);
   if (recordCustom && metrics > 0)                                      return(!onInputError("ValidateInputs(33)  "+ sequence.name +" invalid parameter EA.Recorder: "+ DoubleQuoteStr(EA.Recorder) +" (unsupported metric "+ metrics +")"));

   SS.All();
   return(!catch("ValidateInputs(34)"));
}


/**
 * Error handler for invalid input parameters. Depending on the execution context a (non-)terminating error is set.
 *
 * @param  string message - error message
 *
 * @return int - error status
 */
int onInputError(string message) {
   int error = ERR_INVALID_PARAMETER;

   if (ProgramInitReason() == IR_PARAMETERS)
      return(logError(message, error));                           // non-terminating error
   return(catch(message, error));                                 // terminating error
}


/**
 * Add an order record to the order arrays. Records are ordered ascending by grid level and the new record is inserted at the
 * correct position. No data is overwritten.
 *
 * @param  int direction - trade direction of the record
 * @param  ...
 *
 * @return int - index the record was inserted at or EMPTY (-1) in case of errors
 */
int Orders.AddRecord(int direction, int ticket, int level, double lots, int pendingType, datetime pendingTime, double pendingPrice, int openType, datetime openTime, double openPrice, datetime closeTime, double closePrice, double swap, double commission, double profit) {
   int i;

   if (direction == D_LONG) {
      int size = ArraySize(long.ticket);

      for (i=0; i < size; i++) {
         if (long.level[i] == level) return(_EMPTY(catch("Orders.AddRecord(1)  "+ sequence.name +" cannot overwrite ticket #"+ long.ticket[i] +" of level "+ level +" (index "+ i +")", ERR_ILLEGAL_STATE)));
         if (long.level[i] > level)  break;
      }
      ArrayInsertInt   (long.ticket,       i, ticket                               );
      ArrayInsertInt   (long.level,        i, level                                );
      ArrayInsertDouble(long.lots,         i, NormalizeDouble(lots, 2)             );
      ArrayInsertInt   (long.pendingType,  i, pendingType                          );
      ArrayInsertInt   (long.pendingTime,  i, pendingTime                          );
      ArrayInsertDouble(long.pendingPrice, i, NormalizeDouble(pendingPrice, Digits));
      ArrayInsertInt   (long.openType,     i, openType                             );
      ArrayInsertInt   (long.openTime,     i, openTime                             );
      ArrayInsertDouble(long.openPrice,    i, openPrice                            );
      ArrayInsertInt   (long.closeTime,    i, closeTime                            );
      ArrayInsertDouble(long.closePrice,   i, closePrice                           );
      ArrayInsertDouble(long.swap,         i, swap                                 );
      ArrayInsertDouble(long.commission,   i, commission                           );
      ArrayInsertDouble(long.profit,       i, profit                               );
   }

   else if (direction == D_SHORT) {
      size = ArraySize(short.ticket);

      for (i=0; i < size; i++) {
         if (short.level[i] == level) return(_EMPTY(catch("Orders.AddRecord(2)  "+ sequence.name +" cannot overwrite ticket #"+ short.ticket[i] +" of level "+ level +" (index "+ i +")", ERR_ILLEGAL_STATE)));
         if (short.level[i] > level)  break;
      }
      ArrayInsertInt   (short.ticket,       i, ticket                               );
      ArrayInsertInt   (short.level,        i, level                                );
      ArrayInsertDouble(short.lots,         i, NormalizeDouble(lots, 2)             );
      ArrayInsertInt   (short.pendingType,  i, pendingType                          );
      ArrayInsertInt   (short.pendingTime,  i, pendingTime                          );
      ArrayInsertDouble(short.pendingPrice, i, NormalizeDouble(pendingPrice, Digits));
      ArrayInsertInt   (short.openType,     i, openType                             );
      ArrayInsertInt   (short.openTime,     i, openTime                             );
      ArrayInsertDouble(short.openPrice,    i, openPrice                            );
      ArrayInsertInt   (short.closeTime,    i, closeTime                            );
      ArrayInsertDouble(short.closePrice,   i, closePrice                           );
      ArrayInsertDouble(short.swap,         i, swap                                 );
      ArrayInsertDouble(short.commission,   i, commission                           );
      ArrayInsertDouble(short.profit,       i, profit                               );
   }
   else return(_EMPTY(catch("Orders.AddRecord(3)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER)));

   if (!catch("Orders.AddRecord(4)"))
      return(i);
   return(EMPTY);
}


/**
 * Remove the order record at the specified offset from the order arrays. After removal the array size has decreased.
 *
 * @param  int direction
 * @param  int offset    - position (array index) of the record to remove
 *
 * @return bool - success status
 */
bool Orders.RemoveRecord(int direction, int offset) {
   if (direction == D_LONG) {
      if (offset < 0 || offset >= ArraySize(long.ticket)) return(!catch("Orders.RemoveRecord(1)  "+ sequence.name +" invalid parameter offset: "+ offset +" (long order array size: "+ ArraySize(long.ticket) +")", ERR_INVALID_PARAMETER));
      ArraySpliceInts   (long.ticket,       offset, 1);
      ArraySpliceInts   (long.level,        offset, 1);
      ArraySpliceDoubles(long.lots,         offset, 1);
      ArraySpliceInts   (long.pendingType,  offset, 1);
      ArraySpliceInts   (long.pendingTime,  offset, 1);
      ArraySpliceDoubles(long.pendingPrice, offset, 1);
      ArraySpliceInts   (long.openType,     offset, 1);
      ArraySpliceInts   (long.openTime,     offset, 1);
      ArraySpliceDoubles(long.openPrice,    offset, 1);
      ArraySpliceInts   (long.closeTime,    offset, 1);
      ArraySpliceDoubles(long.closePrice,   offset, 1);
      ArraySpliceDoubles(long.swap,         offset, 1);
      ArraySpliceDoubles(long.commission,   offset, 1);
      ArraySpliceDoubles(long.profit,       offset, 1);
   }
   else if (direction == D_SHORT) {
      if (offset < 0 || offset >= ArraySize(short.ticket)) return(!catch("Orders.RemoveRecord(2)  "+ sequence.name +" invalid parameter offset: "+ offset +" (short order array size: "+ ArraySize(short.ticket) +")", ERR_INVALID_PARAMETER));
      ArraySpliceInts   (short.ticket,       offset, 1);
      ArraySpliceInts   (short.level,        offset, 1);
      ArraySpliceDoubles(short.lots,         offset, 1);
      ArraySpliceInts   (short.pendingType,  offset, 1);
      ArraySpliceInts   (short.pendingTime,  offset, 1);
      ArraySpliceDoubles(short.pendingPrice, offset, 1);
      ArraySpliceInts   (short.openType,     offset, 1);
      ArraySpliceInts   (short.openTime,     offset, 1);
      ArraySpliceDoubles(short.openPrice,    offset, 1);
      ArraySpliceInts   (short.closeTime,    offset, 1);
      ArraySpliceDoubles(short.closePrice,   offset, 1);
      ArraySpliceDoubles(short.swap,         offset, 1);
      ArraySpliceDoubles(short.commission,   offset, 1);
      ArraySpliceDoubles(short.profit,       offset, 1);
   }
   else return(!catch("Orders.RemoveRecord(3)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));

   return(!catch("Orders.RemoveRecord(4)"));
}


/**
 * Add a history record to the history arrays. Prevents existing data to be overwritten.
 *
 * @param  int direction - trade direction of the record
 * @param  int index     - array index to insert the record
 * @param  int cycle     - trade cycle the record belongs to
 * @param  ...
 *
 * @return bool - success status
 */
int History.AddRecord(int direction, int index, int cycle, double gridbase, datetime startTime, double startPrice, datetime stopTime, double stopPrice, double totalProfit, double maxProfit, double maxDrawdown, int ticket, int level, double lots, int pendingType, datetime pendingTime, double pendingPrice, int openType, datetime openTime, double openPrice, datetime closeTime, double closePrice, double swap, double commission, double profit) {
   if (index < 0) return(!catch("History.AddRecord(1)  "+ sequence.name +" invalid parameter index: "+ index, ERR_INVALID_PARAMETER));

   if (direction == D_LONG) {
      int size = ArrayRange(long.history, 0);
      if (index >= size) ArrayResize(long.history, index+1);
      if (long.history[index][HI_CYCLE] != 0) return(!catch("History.AddRecord(2)  "+ sequence.name +" invalid parameter index: "+ index +" (cannot overwrite long.history[] record, cycle="+ long.history[index][HI_CYCLE] +", ticket #"+ long.history[index][HI_TICKET] +")", ERR_INVALID_PARAMETER));

      long.history[index][HI_CYCLE       ] = cycle;
      long.history[index][HI_STARTTIME   ] = startTime;
      long.history[index][HI_STARTPRICE  ] = startPrice;
      long.history[index][HI_GRIDBASE    ] = gridbase;
      long.history[index][HI_STOPTIME    ] = stopTime;
      long.history[index][HI_STOPPRICE   ] = stopPrice;
      long.history[index][HI_TOTALPROFIT ] = totalProfit;
      long.history[index][HI_MAXPROFIT   ] = maxProfit;
      long.history[index][HI_MAXDRAWDOWN ] = maxDrawdown;
      long.history[index][HI_TICKET      ] = ticket;
      long.history[index][HI_LEVEL       ] = level;
      long.history[index][HI_LOTS        ] = lots;
      long.history[index][HI_PENDINGTYPE ] = pendingType;
      long.history[index][HI_PENDINGTIME ] = pendingTime;
      long.history[index][HI_PENDINGPRICE] = pendingPrice;
      long.history[index][HI_OPENTYPE    ] = openType;
      long.history[index][HI_OPENTIME    ] = openTime;
      long.history[index][HI_OPENPRICE   ] = openPrice;
      long.history[index][HI_CLOSETIME   ] = closeTime;
      long.history[index][HI_CLOSEPRICE  ] = closePrice;
      long.history[index][HI_SWAP        ] = swap;
      long.history[index][HI_COMMISSION  ] = commission;
      long.history[index][HI_PROFIT      ] = profit;
   }
   else if (direction == D_SHORT) {
      size = ArrayRange(short.history, 0);
      if (index >= size) ArrayResize(short.history, index+1);
      if (short.history[index][HI_CYCLE] != 0) return(!catch("History.AddRecord(3)  "+ sequence.name +" invalid parameter index: "+ index +" (cannot overwrite short.history[] record, cycle="+ short.history[index][HI_CYCLE] +", ticket #"+ short.history[index][HI_TICKET] +")", ERR_INVALID_PARAMETER));

      short.history[index][HI_CYCLE       ] = cycle;
      short.history[index][HI_STARTTIME   ] = startTime;
      short.history[index][HI_STARTPRICE  ] = startPrice;
      short.history[index][HI_GRIDBASE    ] = gridbase;
      short.history[index][HI_STOPTIME    ] = stopTime;
      short.history[index][HI_STOPPRICE   ] = stopPrice;
      short.history[index][HI_TOTALPROFIT ] = totalProfit;
      short.history[index][HI_MAXPROFIT   ] = maxProfit;
      short.history[index][HI_MAXDRAWDOWN ] = maxDrawdown;
      short.history[index][HI_TICKET      ] = ticket;
      short.history[index][HI_LEVEL       ] = level;
      short.history[index][HI_LOTS        ] = lots;
      short.history[index][HI_PENDINGTYPE ] = pendingType;
      short.history[index][HI_PENDINGTIME ] = pendingTime;
      short.history[index][HI_PENDINGPRICE] = pendingPrice;
      short.history[index][HI_OPENTYPE    ] = openType;
      short.history[index][HI_OPENTIME    ] = openTime;
      short.history[index][HI_OPENPRICE   ] = openPrice;
      short.history[index][HI_CLOSETIME   ] = closeTime;
      short.history[index][HI_CLOSEPRICE  ] = closePrice;
      short.history[index][HI_SWAP        ] = swap;
      short.history[index][HI_COMMISSION  ] = commission;
      short.history[index][HI_PROFIT      ] = profit;
   }
   else return(!catch("History.AddRecord(4)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));

   return(!catch("History.AddRecord(5)"));
}


/**
 * Reset all order and history data of the specified trade direction (order log, history and statistics).
 *
 * @param  int direction - D_LONG:  long order data
 *                         D_SHORT: short order data
 * @return bool - success status
 */
bool ResetOrderLog(int direction) {
   if (direction == D_LONG) {
      long.enabled  = false;
      long.openLots = 0;
      long.slippage = 0;
      long.openPL   = 0;
      long.closedPL = 0;
      long.bePrice  = 0;
      long.minLevel = INT_MAX;
      long.maxLevel = INT_MIN;

      ArrayResize(long.ticket,       0);
      ArrayResize(long.level,        0);
      ArrayResize(long.lots,         0);
      ArrayResize(long.pendingType,  0);
      ArrayResize(long.pendingTime,  0);
      ArrayResize(long.pendingPrice, 0);
      ArrayResize(long.openType,     0);
      ArrayResize(long.openTime,     0);
      ArrayResize(long.openPrice,    0);
      ArrayResize(long.closeTime,    0);
      ArrayResize(long.closePrice,   0);
      ArrayResize(long.swap,         0);
      ArrayResize(long.commission,   0);
      ArrayResize(long.profit,       0);
      ArrayResize(long.history,      0);
      return(true);
   }

   if (direction == D_SHORT) {
      short.enabled  = false;
      short.openLots = 0;
      short.slippage = 0;
      short.openPL   = 0;
      short.closedPL = 0;
      short.bePrice  = 0;
      short.minLevel = INT_MAX;
      short.maxLevel = INT_MIN;

      ArrayResize(short.ticket,       0);
      ArrayResize(short.level,        0);
      ArrayResize(short.lots,         0);
      ArrayResize(short.pendingType,  0);
      ArrayResize(short.pendingTime,  0);
      ArrayResize(short.pendingPrice, 0);
      ArrayResize(short.openType,     0);
      ArrayResize(short.openTime,     0);
      ArrayResize(short.openPrice,    0);
      ArrayResize(short.closeTime,    0);
      ArrayResize(short.closePrice,   0);
      ArrayResize(short.swap,         0);
      ArrayResize(short.commission,   0);
      ArrayResize(short.profit,       0);
      ArrayResize(short.history,      0);
      return(true);
   }

   return(!catch("ResetOrderLog(1)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));
}


/**
 * Move existing sequence data to the archive. Called from ResumeSequence() to prepare continuation of a stopped sequence.
 *
 * @return bool - success status
 */
bool ArchiveStoppedSequence() {
   if (IsLastError())                     return(false);
   if (sequence.status != STATUS_STOPPED) return(!catch("ArchiveStoppedSequence(1)  "+ sequence.name +" cannot archive data of "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));

   // long
   if (long.enabled) {
      int historySize = ArrayRange(long.history, 0);
      int ordersSize  = ArraySize(long.ticket);
      ArrayResize(long.history, historySize + ordersSize);

      for (int i=0; i < ordersSize; i++) {
         long.history[historySize+i][HI_CYCLE       ] = sequence.cycle;         // for simplicity sequence data is duplicated
         long.history[historySize+i][HI_STARTTIME   ] = sequence.startTime;     //
         long.history[historySize+i][HI_STARTPRICE  ] = sequence.startPrice;    //
         long.history[historySize+i][HI_GRIDBASE    ] = sequence.gridbase;      //
         long.history[historySize+i][HI_STOPTIME    ] = sequence.stopTime;      //
         long.history[historySize+i][HI_STOPPRICE   ] = sequence.stopPrice;     //
         long.history[historySize+i][HI_TOTALPROFIT ] = sequence.totalPL;       //
         long.history[historySize+i][HI_MAXPROFIT   ] = sequence.maxProfit;     //
         long.history[historySize+i][HI_MAXDRAWDOWN ] = sequence.maxDrawdown;   //
         long.history[historySize+i][HI_TICKET      ] = long.ticket      [i];
         long.history[historySize+i][HI_LEVEL       ] = long.level       [i];
         long.history[historySize+i][HI_LOTS        ] = long.lots        [i];
         long.history[historySize+i][HI_PENDINGTYPE ] = long.pendingType [i];
         long.history[historySize+i][HI_PENDINGTIME ] = long.pendingTime [i];
         long.history[historySize+i][HI_PENDINGPRICE] = long.pendingPrice[i];
         long.history[historySize+i][HI_OPENTYPE    ] = long.openType    [i];
         long.history[historySize+i][HI_OPENTIME    ] = long.openTime    [i];
         long.history[historySize+i][HI_OPENPRICE   ] = long.openPrice   [i];
         long.history[historySize+i][HI_CLOSETIME   ] = long.closeTime   [i];
         long.history[historySize+i][HI_CLOSEPRICE  ] = long.closePrice  [i];
         long.history[historySize+i][HI_SWAP        ] = long.swap        [i];
         long.history[historySize+i][HI_COMMISSION  ] = long.commission  [i];
         long.history[historySize+i][HI_PROFIT      ] = long.profit      [i];
      }
      ArrayResize(long.ticket,       0);
      ArrayResize(long.level,        0);
      ArrayResize(long.lots,         0);
      ArrayResize(long.pendingType,  0);
      ArrayResize(long.pendingTime,  0);
      ArrayResize(long.pendingPrice, 0);
      ArrayResize(long.openType,     0);
      ArrayResize(long.openTime,     0);
      ArrayResize(long.openPrice,    0);
      ArrayResize(long.closeTime,    0);
      ArrayResize(long.closePrice,   0);
      ArrayResize(long.swap,         0);
      ArrayResize(long.commission,   0);
      ArrayResize(long.profit,       0);
   }

   // short
   if (short.enabled) {
      historySize = ArrayRange(short.history, 0);
      ordersSize  = ArraySize(short.ticket);
      ArrayResize(short.history, historySize + ordersSize);

      for (i=0; i < ordersSize; i++) {
         short.history[historySize+i][HI_CYCLE       ] = sequence.cycle;         // for simplicity sequence data is duplicated
         short.history[historySize+i][HI_STARTTIME   ] = sequence.startTime;     //
         short.history[historySize+i][HI_STARTPRICE  ] = sequence.startPrice;    //
         short.history[historySize+i][HI_GRIDBASE    ] = sequence.gridbase;      //
         short.history[historySize+i][HI_STOPTIME    ] = sequence.stopTime;      //
         short.history[historySize+i][HI_STOPPRICE   ] = sequence.stopPrice;     //
         short.history[historySize+i][HI_TOTALPROFIT ] = sequence.totalPL;       //
         short.history[historySize+i][HI_MAXPROFIT   ] = sequence.maxProfit;     //
         short.history[historySize+i][HI_MAXDRAWDOWN ] = sequence.maxDrawdown;   //
         short.history[historySize+i][HI_TICKET      ] = short.ticket      [i];
         short.history[historySize+i][HI_LEVEL       ] = short.level       [i];
         short.history[historySize+i][HI_LOTS        ] = short.lots        [i];
         short.history[historySize+i][HI_PENDINGTYPE ] = short.pendingType [i];
         short.history[historySize+i][HI_PENDINGTIME ] = short.pendingTime [i];
         short.history[historySize+i][HI_PENDINGPRICE] = short.pendingPrice[i];
         short.history[historySize+i][HI_OPENTYPE    ] = short.openType    [i];
         short.history[historySize+i][HI_OPENTIME    ] = short.openTime    [i];
         short.history[historySize+i][HI_OPENPRICE   ] = short.openPrice   [i];
         short.history[historySize+i][HI_CLOSETIME   ] = short.closeTime   [i];
         short.history[historySize+i][HI_CLOSEPRICE  ] = short.closePrice  [i];
         short.history[historySize+i][HI_SWAP        ] = short.swap        [i];
         short.history[historySize+i][HI_COMMISSION  ] = short.commission  [i];
         short.history[historySize+i][HI_PROFIT      ] = short.profit      [i];
      }
      ArrayResize(short.ticket,       0);
      ArrayResize(short.level,        0);
      ArrayResize(short.lots,         0);
      ArrayResize(short.pendingType,  0);
      ArrayResize(short.pendingTime,  0);
      ArrayResize(short.pendingPrice, 0);
      ArrayResize(short.openType,     0);
      ArrayResize(short.openTime,     0);
      ArrayResize(short.openPrice,    0);
      ArrayResize(short.closeTime,    0);
      ArrayResize(short.closePrice,   0);
      ArrayResize(short.swap,         0);
      ArrayResize(short.commission,   0);
      ArrayResize(short.profit,       0);
   }

   return(!catch("ArchiveStoppedSequence(2)"));
}


/**
 * Open a market position at the current price.
 *
 * @param  _In_  int direction - trade direction
 * @param  _In_  int level     - order gridlevel
 * @param  _Out_ int oe[]      - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket or NULL in case of errors
 */
int SubmitMarketOrder(int direction, int level, int oe[]) {
   if (IsLastError())                           return(NULL);
   if (sequence.status != STATUS_PROGRESSING)   return(!catch("SubmitMarketOrder(1)  "+ sequence.name +" cannot submit market order for "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (direction!=D_LONG && direction!=D_SHORT) return(!catch("SubmitMarketOrder(2)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));
   if (!level || level==-1)                     return(!catch("SubmitMarketOrder(3)  "+ sequence.name +" invalid parameter level: "+ level, ERR_INVALID_PARAMETER));

   int      type        = ifInt(direction==D_LONG, OP_BUY, OP_SELL);
   double   lots        = CalculateLots(direction, level);
   double   price       = NULL;
   int      slippage    = 1;
   double   stopLoss    = NULL;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "Duel."+ ifString(direction==D_LONG, "L.", "S.") + sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = ifInt(direction==D_LONG, CLR_OPEN_LONG, CLR_OPEN_SHORT);
   int      oeFlags     = NULL;

   int ticket = OrderSendEx(Symbol(), type, lots, price, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   return(!SetLastError(oe.Error(oe)));
}


/**
 * Open a pending limit order.
 *
 * @param  _In_  int direction - trade direction
 * @param  _In_  int level     - order gridlevel
 * @param  _Out_ int oe[]      - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket or NULL in case of errors
 */
int SubmitLimitOrder(int direction, int level, int &oe[]) {
   if (IsLastError())                           return(NULL);
   if (sequence.status!=STATUS_PROGRESSING)     return(!catch("SubmitLimitOrder(1)  "+ sequence.name +" cannot submit limit order for "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (direction!=D_LONG && direction!=D_SHORT) return(!catch("SubmitLimitOrder(2)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));
   if (!level || level==-1)                     return(!catch("SubmitLimitOrder(3)  "+ sequence.name +" invalid parameter level: "+ level, ERR_INVALID_PARAMETER));

   int      type        = ifInt(direction==D_LONG, OP_BUYLIMIT, OP_SELLLIMIT);
   double   lots        = CalculateLots(direction, level);
   double   price       = CalculateGridLevel(direction, level);
   int      slippage    = NULL;
   double   stopLoss    = NULL;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "Duel."+ ifString(direction==D_LONG, "L.", "S.") + sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = CLR_OPEN_PENDING;
   int      oeFlags     = F_ERR_INVALID_STOP;         // custom handling of ERR_INVALID_STOP (market violated)

   int ticket = OrderSendEx(Symbol(), type, lots, price, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   int error = oe.Error(oe);
   if (error != ERR_INVALID_STOP)
      SetLastError(error);
   return(NULL);
}


/**
 * Open a pending stop order.
 *
 * @param  _In_  int direction - trade direction
 * @param  _In_  int level     - order gridlevel
 * @param  _Out_ int oe[]      - execution details (struct ORDER_EXECUTION)
 *
 * @return int - order ticket or NULL in case of errors
 */
int SubmitStopOrder(int direction, int level, int &oe[]) {
   if (IsLastError())                           return(NULL);
   if (sequence.status!=STATUS_PROGRESSING)     return(!catch("SubmitStopOrder(1)  "+ sequence.name +" cannot submit stop order for "+ StatusDescription(sequence.status) +" sequence", ERR_ILLEGAL_STATE));
   if (direction!=D_LONG && direction!=D_SHORT) return(!catch("SubmitStopOrder(2)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER));
   if (!level || level==-1)                     return(!catch("SubmitStopOrder(3)  "+ sequence.name +" invalid parameter level: "+ level, ERR_INVALID_PARAMETER));

   int      type        = ifInt(direction==D_LONG, OP_BUYSTOP, OP_SELLSTOP);
   double   lots        = CalculateLots(direction, level);
   double   price       = CalculateGridLevel(direction, level);
   int      slippage    = NULL;
   double   stopLoss    = NULL;
   double   takeProfit  = NULL;
   int      magicNumber = CreateMagicNumber(level);
   datetime expires     = NULL;
   string   comment     = "Duel."+ ifString(direction==D_LONG, "L.", "S.") + sequence.id +"."+ NumberToStr(level, "+.");
   color    markerColor = CLR_OPEN_PENDING;
   int      oeFlags     = F_ERR_INVALID_STOP;         // custom handling of ERR_INVALID_STOP (market violated)

   int ticket = OrderSendEx(Symbol(), type, lots, price, slippage, stopLoss, takeProfit, comment, magicNumber, expires, markerColor, oeFlags, oe);
   if (ticket > 0) return(ticket);

   int error = oe.Error(oe);
   if (error != ERR_INVALID_STOP)
      SetLastError(error);
   return(NULL);
}


/**
 * Resolve the current Average Daily Range.
 *
 * @return double - ADR value or NULL in case of errors
 */
double GetADR() {
   static double adr = 0;                                   // TODO: invalidate static var on BarOpen(D1)
   if (!adr) adr = iADR();
   return(adr);
}


/**
 * Write the current sequence status to a file.
 *
 * @return bool - success status
 */
bool SaveStatus() {
   if (last_error != NULL)                       return(false);
   if (!sequence.id || StrTrim(Sequence.ID)=="") return(!catch("SaveStatus(1)  illegal sequence id: "+ sequence.id +" (Sequence.ID="+ DoubleQuoteStr(Sequence.ID) +")", ERR_ILLEGAL_STATE));
   if (IsTestSequence() && !__isTesting)         return(true);  // don't change the status file of a finished test

   // in tester skip most status file writes, except file creation, sequence stop and test end
   if (__isTesting && test.reduceStatusWrites) {
      static bool saved = false;
      if (saved && sequence.status!=STATUS_STOPPED && __CoreFunction!=CF_DEINIT) return(true);
      saved = true;
   }

   string section="", separator="", file=GetStatusFilename();
   if (!IsFile(file, MODE_SYSTEM)) separator = CRLF;            // an empty line as additional section separator

   // [General]
   section = "General";
   WriteIniString(file, section, "Account", GetAccountCompanyId() +":"+ GetAccountNumber());
   WriteIniString(file, section, "Symbol",  Symbol());
   WriteIniString(file, section, "Created", GmtTimeFormat(sequence.created, "%a, %Y.%m.%d %H:%M:%S") + separator);            // conditional section separator

   // [Inputs]
   section = "Inputs";
   WriteIniString(file, section, "Sequence.ID",                 /*string  */ Sequence.ID);
   WriteIniString(file, section, "GridDirection",               /*string  */ GridDirection);
   WriteIniString(file, section, "GridVolatility",              /*string  */ NumberToStr(NormalizeDouble(sequence.gridvola, 1), ".+") +"%");
   WriteIniString(file, section, "GridSize",                    /*string  */ PipToStr(sequence.gridsize));
   WriteIniString(file, section, "UnitSize",                    /*double  */ NumberToStr(sequence.unitsize, ".+"));
   WriteIniString(file, section, "MaxUnits",                    /*int     */ MaxUnits);
   WriteIniString(file, section, "Pyramid.Multiplier",          /*double  */ NumberToStr(Pyramid.Multiplier, ".+"));
   WriteIniString(file, section, "Martingale.Multiplier",       /*double  */ NumberToStr(Martingale.Multiplier, ".+"));
   WriteIniString(file, section, "StopConditions",              /*string  */ SaveStatus.ConditionsToStr(sStopConditions));    // contains only active conditions
   WriteIniString(file, section, "ShowProfitInPercent",         /*bool    */ ShowProfitInPercent);
   WriteIniString(file, section, "Sessionbreak.StartTime",      /*datetime*/ Sessionbreak.StartTime + ifString(Sessionbreak.StartTime, GmtTimeFormat(Sessionbreak.StartTime, " (%a, %Y.%m.%d %H:%M:%S)"), ""));
   WriteIniString(file, section, "Sessionbreak.EndTime",        /*datetime*/ Sessionbreak.EndTime   + ifString(Sessionbreak.EndTime,   GmtTimeFormat(Sessionbreak.EndTime,   " (%a, %Y.%m.%d %H:%M:%S)"), ""));
   WriteIniString(file, section, "EA.Recorder",                 /*string  */ EA.Recorder + separator);                        // conditional section separator

   // [Runtime status]
   section = "Runtime status";            // On deletion of pending orders the number of stored order records decreases. To prevent
   EmptyIniSectionA(file, section);       // orphaned status file records the section is emptied before writing to it.

   // sequence data
   WriteIniString(file, section, "sequence.id",                 /*int     */ sequence.id);
   WriteIniString(file, section, "sequence.created",            /*datetime*/ sequence.created + GmtTimeFormat(sequence.created, " (%a, %Y.%m.%d %H:%M:%S)"));
   WriteIniString(file, section, "sequence.isTest",             /*bool    */ sequence.isTest);
   WriteIniString(file, section, "sequence.name",               /*string  */ sequence.name);
   WriteIniString(file, section, "sequence.cycle",              /*int     */ sequence.cycle);
   WriteIniString(file, section, "sequence.status",             /*int     */ sequence.status);
   WriteIniString(file, section, "sequence.direction",          /*int     */ sequence.direction);
   WriteIniString(file, section, "sequence.pyramidEnabled",     /*bool    */ sequence.pyramidEnabled);
   WriteIniString(file, section, "sequence.martingaleEnabled",  /*bool    */ sequence.martingaleEnabled);
   WriteIniString(file, section, "sequence.gridsize",           /*double  */ NumberToStr(sequence.gridsize, ".+"));
   WriteIniString(file, section, "sequence.unitsize",           /*double  */ NumberToStr(sequence.unitsize, ".+"));
   WriteIniString(file, section, "sequence.gridvola",           /*double  */ NumberToStr(sequence.gridvola, ".+"));
   WriteIniString(file, section, "sequence.gridbase",           /*double  */ DoubleToStr(sequence.gridbase, Digits));
   WriteIniString(file, section, "sequence.startTime",          /*datetime*/ sequence.startTime + ifString(sequence.startTime, GmtTimeFormat(sequence.startTime, " (%a, %Y.%m.%d %H:%M:%S)"), ""));
   WriteIniString(file, section, "sequence.startPrice",         /*double  */ NumberToStr(sequence.startPrice, ".+"));
   WriteIniString(file, section, "sequence.startEquity",        /*double  */ DoubleToStr(sequence.startEquity, 2));
   WriteIniString(file, section, "sequence.stopTime",           /*datetime*/ sequence.stopTime + ifString(sequence.stopTime, GmtTimeFormat(sequence.stopTime, " (%a, %Y.%m.%d %H:%M:%S)"), ""));
   WriteIniString(file, section, "sequence.stopPrice",          /*double  */ NumberToStr(sequence.stopPrice, ".+"));
   WriteIniString(file, section, "sequence.openLots",           /*double  */ NumberToStr(sequence.openLots, ".+"));
   WriteIniString(file, section, "sequence.avgOpenPrice",       /*double  */ NumberToStr(sequence.avgOpenPrice, ".+"));
   WriteIniString(file, section, "sequence.floatingCommission", /*double  */ DoubleToStr(sequence.floatingCommission, 2));
   WriteIniString(file, section, "sequence.floatingSwap",       /*double  */ DoubleToStr(sequence.floatingSwap, 2));
   WriteIniString(file, section, "sequence.floatingPL",         /*double  */ DoubleToStr(sequence.floatingPL, 2));
   WriteIniString(file, section, "sequence.hedgedPL",           /*double  */ DoubleToStr(sequence.hedgedPL, 2));
   WriteIniString(file, section, "sequence.openPL",             /*double  */ DoubleToStr(sequence.openPL, 2));
   WriteIniString(file, section, "sequence.closedPL",           /*double  */ DoubleToStr(sequence.closedPL, 2));
   WriteIniString(file, section, "sequence.totalPL",            /*double  */ DoubleToStr(sequence.totalPL, 2));
   WriteIniString(file, section, "sequence.maxProfit",          /*double  */ DoubleToStr(sequence.maxProfit, 2));
   WriteIniString(file, section, "sequence.maxDrawdown",        /*double  */ DoubleToStr(sequence.maxDrawdown, 2));
   WriteIniString(file, section, "sequence.tpPrice",            /*double  */ NumberToStr(sequence.tpPrice, ".+"));
   WriteIniString(file, section, "sequence.slPrice",            /*double  */ NumberToStr(sequence.slPrice, ".+") + CRLF);

   // long order data
   WriteIniString(file, section, "long.enabled",                /*bool     */ long.enabled);
   int size = ArraySize(long.ticket);
   for (int i=0; i < size; i++) {
      WriteIniString(file, section, "long.orders."+ i, SaveStatus.OrderToStr(D_LONG, i));
   }
   size = ArrayRange(long.history, 0);
   for (i=0; i < size; i++) {
      WriteIniString(file, section, "long.history."+ i, SaveStatus.HistoryToStr(D_LONG, i));
   }
   WriteIniString(file, section, "long.openLots",               /*double  */ NumberToStr(long.openLots, ".+"));
   WriteIniString(file, section, "long.slippage",               /*double  */ NumberToStr(long.slippage, ".+"));
   WriteIniString(file, section, "long.openPL",                 /*double  */ DoubleToStr(long.openPL, 2));
   WriteIniString(file, section, "long.closedPL",               /*double  */ DoubleToStr(long.closedPL, 2));
   WriteIniString(file, section, "long.bePrice",                /*double  */ NumberToStr(long.bePrice, ".+"));
   WriteIniString(file, section, "long.minLevel",               /*int     */ long.minLevel);
   WriteIniString(file, section, "long.maxLevel",               /*int     */ long.maxLevel + CRLF);

   // short order data
   WriteIniString(file, section, "short.enabled",               /*bool    */ short.enabled);
   size = ArraySize(short.ticket);
   for (i=0; i < size; i++) {
      WriteIniString(file, section, "short.orders."+ i, SaveStatus.OrderToStr(D_SHORT, i));
   }
   size = ArrayRange(short.history, 0);
   for (i=0; i < size; i++) {
      WriteIniString(file, section, "short.history."+ i, SaveStatus.HistoryToStr(D_SHORT, i));
   }
   WriteIniString(file, section, "short.openLots",              /*double  */ NumberToStr(short.openLots, ".+"));
   WriteIniString(file, section, "short.slippage",              /*double  */ NumberToStr(short.slippage, ".+"));
   WriteIniString(file, section, "short.openPL",                /*double  */ DoubleToStr(short.openPL, 2));
   WriteIniString(file, section, "short.closedPL",              /*double  */ DoubleToStr(short.closedPL, 2));
   WriteIniString(file, section, "short.bePrice",               /*double  */ NumberToStr(short.bePrice, ".+"));
   WriteIniString(file, section, "short.minLevel",              /*int     */ short.minLevel);
   WriteIniString(file, section, "short.maxLevel",              /*int     */ short.maxLevel + CRLF);

   // other
   WriteIniString(file, section, "stop.price.condition",        /*bool    */ stop.price.condition);
   WriteIniString(file, section, "stop.price.type",             /*int     */ stop.price.type);
   WriteIniString(file, section, "stop.price.value",            /*double  */ NumberToStr(stop.price.value, ".+"));
   WriteIniString(file, section, "stop.price.lastValue",        /*double  */ NumberToStr(stop.price.lastValue, ".+"));
   WriteIniString(file, section, "stop.price.description",      /*string  */ stop.price.description + CRLF);

   WriteIniString(file, section, "stop.profitAbs.condition",    /*bool    */ stop.profitAbs.condition);
   WriteIniString(file, section, "stop.profitAbs.value",        /*double  */ DoubleToStr(stop.profitAbs.value, 2));
   WriteIniString(file, section, "stop.profitAbs.description",  /*string  */ stop.profitAbs.description);
   WriteIniString(file, section, "stop.profitPct.condition",    /*bool    */ stop.profitPct.condition);
   WriteIniString(file, section, "stop.profitPct.value",        /*double  */ NumberToStr(stop.profitPct.value, ".+"));
   WriteIniString(file, section, "stop.profitPct.absValue",     /*double  */ ifString(stop.profitPct.absValue==INT_MAX, INT_MAX, DoubleToStr(stop.profitPct.absValue, 2)));
   WriteIniString(file, section, "stop.profitPct.description",  /*string  */ stop.profitPct.description + CRLF);

   WriteIniString(file, section, "stop.lossAbs.condition",      /*bool    */ stop.lossAbs.condition  );
   WriteIniString(file, section, "stop.lossAbs.value",          /*double  */ DoubleToStr(stop.lossAbs.value, 2));
   WriteIniString(file, section, "stop.lossAbs.description",    /*string  */ stop.lossAbs.description);
   WriteIniString(file, section, "stop.lossPct.condition",      /*bool    */ stop.lossPct.condition  );
   WriteIniString(file, section, "stop.lossPct.value",          /*double  */ NumberToStr(stop.lossPct.value, ".+"));
   WriteIniString(file, section, "stop.lossPct.absValue",       /*double  */ ifString(stop.lossPct.absValue==INT_MIN, INT_MIN, DoubleToStr(stop.lossPct.absValue, 2)));
   WriteIniString(file, section, "stop.lossPct.description",    /*string  */ stop.lossPct.description + CRLF);

   WriteIniString(file, section, "sessionbreak.starttime",      /*datetime*/ sessionbreak.starttime + ifString(sessionbreak.starttime, GmtTimeFormat(sessionbreak.starttime, " (%a, %Y.%m.%d %H:%M:%S)"), ""));
   WriteIniString(file, section, "sessionbreak.endtime",        /*datetime*/ sessionbreak.endtime   + ifString(sessionbreak.endtime,   GmtTimeFormat(sessionbreak.endtime,   " (%a, %Y.%m.%d %H:%M:%S)"), "") + CRLF);

   return(!catch("SaveStatus(2)"));
}


/**
 * Return a string representation of only active stop conditions to be stored by SaveStatus().
 *
 * @param  string sConditions - active and inactive conditions
 *
 * @param  string - active conditions
 */
string SaveStatus.ConditionsToStr(string sConditions) {
   sConditions = StrTrim(sConditions);
   if (!StringLen(sConditions) || sConditions=="-") return("");

   string values[], expr="", result="";
   int size = Explode(sConditions, "|", values, NULL);

   for (int i=0; i < size; i++) {
      expr = StrTrim(values[i]);
      if (!StringLen(expr))              continue;              // skip empty conditions
      if (StringGetChar(expr, 0) == '!') continue;              // skip disabled conditions
      result = StringConcatenate(result, " | ", expr);
   }
   if (StringLen(result) > 0) {
      result = StrRight(result, -3);
   }
   return(result);
}


/**
 * Return a string representation of an order record to be stored by SaveStatus().
 *
 * @param  int direction - D_LONG | D_SHORT
 * @param  int index     - index of the order record
 *
 * @return string - string representation or an empty string in case of errors
 */
string SaveStatus.OrderToStr(int direction, int index) {
   int      ticket, level, pendingType, openType;
   datetime pendingTime, openTime, closeTime;
   double   lots, pendingPrice, openPrice, closePrice, swap, commission, profit;

   // result: ticket,level,lots,pendingType,pendingTime,pendingPrice,openType,openTime,openPrice,closeTime,closePrice,swap,commission,profit

   if (direction == D_LONG) {
      ticket       = long.ticket      [index];
      level        = long.level       [index];
      lots         = long.lots        [index];
      pendingType  = long.pendingType [index];
      pendingTime  = long.pendingTime [index];
      pendingPrice = long.pendingPrice[index];
      openType     = long.openType    [index];
      openTime     = long.openTime    [index];
      openPrice    = long.openPrice   [index];
      closeTime    = long.closeTime   [index];
      closePrice   = long.closePrice  [index];
      swap         = long.swap        [index];
      commission   = long.commission  [index];
      profit       = long.profit      [index];
   }
   else if (direction == D_SHORT) {
      ticket       = short.ticket      [index];
      level        = short.level       [index];
      lots         = short.lots        [index];
      pendingType  = short.pendingType [index];
      pendingTime  = short.pendingTime [index];
      pendingPrice = short.pendingPrice[index];
      openType     = short.openType    [index];
      openTime     = short.openTime    [index];
      openPrice    = short.openPrice   [index];
      closeTime    = short.closeTime   [index];
      closePrice   = short.closePrice  [index];
      swap         = short.swap        [index];
      commission   = short.commission  [index];
      profit       = short.profit      [index];
   }
   else return(_EMPTY_STR(catch("SaveStatus.OrderToStr(1)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER)));

   return(StringConcatenate(ticket, ",", level, ",", DoubleToStr(lots, 2), ",", pendingType, ",", pendingTime, ",", DoubleToStr(pendingPrice, Digits), ",", openType, ",", openTime, ",", DoubleToStr(openPrice, Digits), ",", closeTime, ",", DoubleToStr(closePrice, Digits), ",", DoubleToStr(swap, 2), ",", DoubleToStr(commission, 2), ",", DoubleToStr(profit, 2)));
}


/**
 * Return a string representation of a history record to be stored by SaveStatus().
 *
 * @param  int direction - D_LONG | D_SHORT
 * @param  int index     - index of the history record
 *
 * @return string - string representation or an empty string in case of errors
 */
string SaveStatus.HistoryToStr(int direction, int index) {
   int      cycle, ticket, level, pendingType, openType;
   datetime startTime, stopTime, pendingTime, openTime, closeTime;
   double   startPrice, gridbase, stopPrice, totalProfit, maxProfit, maxDrawdown, lots, pendingPrice, openPrice, closePrice, swap, commission, profit;

   // result: cycle,startTime,startPrice,gridbase,stopTime,stopPrice,totalProfit,maxProfit,maxDrawdown,ticket,level,lots,pendingType,pendingTime,pendingPrice,openType,openTime,openPrice,closeTime,closePrice,swap,commission,profit

   if (direction == D_LONG) {
      cycle        = long.history[index][HI_CYCLE       ];
      startTime    = long.history[index][HI_STARTTIME   ];
      startPrice   = long.history[index][HI_STARTPRICE  ];
      gridbase     = long.history[index][HI_GRIDBASE    ];
      stopTime     = long.history[index][HI_STOPTIME    ];
      stopPrice    = long.history[index][HI_STOPPRICE   ];
      totalProfit  = long.history[index][HI_TOTALPROFIT ];
      maxProfit    = long.history[index][HI_MAXPROFIT   ];
      maxDrawdown  = long.history[index][HI_MAXDRAWDOWN ];
      ticket       = long.history[index][HI_TICKET      ];
      level        = long.history[index][HI_LEVEL       ];
      lots         = long.history[index][HI_LOTS        ];
      pendingType  = long.history[index][HI_PENDINGTYPE ];
      pendingTime  = long.history[index][HI_PENDINGTIME ];
      pendingPrice = long.history[index][HI_PENDINGPRICE];
      openType     = long.history[index][HI_OPENTYPE    ];
      openTime     = long.history[index][HI_OPENTIME    ];
      openPrice    = long.history[index][HI_OPENPRICE   ];
      closeTime    = long.history[index][HI_CLOSETIME   ];
      closePrice   = long.history[index][HI_CLOSEPRICE  ];
      swap         = long.history[index][HI_SWAP        ];
      commission   = long.history[index][HI_COMMISSION  ];
      profit       = long.history[index][HI_PROFIT      ];
   }
   else if (direction == D_SHORT) {
      cycle        = short.history[index][HI_CYCLE       ];
      startTime    = short.history[index][HI_STARTTIME   ];
      startPrice   = short.history[index][HI_STARTPRICE  ];
      gridbase     = short.history[index][HI_GRIDBASE    ];
      stopTime     = short.history[index][HI_STOPTIME    ];
      stopPrice    = short.history[index][HI_STOPPRICE   ];
      totalProfit  = short.history[index][HI_TOTALPROFIT ];
      maxProfit    = short.history[index][HI_MAXPROFIT   ];
      maxDrawdown  = short.history[index][HI_MAXDRAWDOWN ];
      ticket       = short.history[index][HI_TICKET      ];
      level        = short.history[index][HI_LEVEL       ];
      lots         = short.history[index][HI_LOTS        ];
      pendingType  = short.history[index][HI_PENDINGTYPE ];
      pendingTime  = short.history[index][HI_PENDINGTIME ];
      pendingPrice = short.history[index][HI_PENDINGPRICE];
      openType     = short.history[index][HI_OPENTYPE    ];
      openTime     = short.history[index][HI_OPENTIME    ];
      openPrice    = short.history[index][HI_OPENPRICE   ];
      closeTime    = short.history[index][HI_CLOSETIME   ];
      closePrice   = short.history[index][HI_CLOSEPRICE  ];
      swap         = short.history[index][HI_SWAP        ];
      commission   = short.history[index][HI_COMMISSION  ];
      profit       = short.history[index][HI_PROFIT      ];
   }
   else return(_EMPTY_STR(catch("SaveStatus.HistoryToStr(1)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER)));

   return(StringConcatenate(cycle, ",", startTime, ",", DoubleToStr(startPrice, Digits), ",", DoubleToStr(gridbase, Digits), ",", stopTime, ",", DoubleToStr(stopPrice, Digits), ",", DoubleToStr(totalProfit, 2), ",", DoubleToStr(maxProfit, 2), ",", DoubleToStr(maxDrawdown, 2), ",", ticket, ",", level, ",", DoubleToStr(lots, 2), ",", pendingType, ",", pendingTime, ",", DoubleToStr(pendingPrice, Digits), ",", openType, ",", openTime, ",", DoubleToStr(openPrice, Digits), ",", closeTime, ",", DoubleToStr(closePrice, Digits), ",", DoubleToStr(swap, 2), ",", DoubleToStr(commission, 2), ",", DoubleToStr(profit, 2)));
}


/**
 * Restore the internal state of the EA from a status file. Requires 'sequence.id' and 'sequence.isTest' to be set.
 *
 * @return bool - success status
 */
bool RestoreSequence() {
   if (IsLastError())     return(false);
   if (!ReadStatus())     return(false);                 // read and apply the status file
   if (!ValidateInputs()) return(false);                 // validate restored input parameters
   //if (!SynchronizeStatus()) return(false);            // synchronize restored state with the trade server
   return(true);
}


/**
 * Read the status file of a sequence and restore inputs and runtime variables. Called only from RestoreSequence().
 * Only syntactical validation is performed (i.e. type match). Logical validation happens in ValidateInputs().
 *
 * @return bool - success status
 */
bool ReadStatus() {
   if (IsLastError()) return(false);
   if (!sequence.id)  return(!catch("ReadStatus(1)  "+ sequence.name +" illegal value of sequence.id: "+ sequence.id, ERR_ILLEGAL_STATE));

   string section="", file=GetStatusFilename();
   if (!IsFile(file, MODE_SYSTEM)) return(!catch("ReadStatus(2)  "+ sequence.name +" status file "+ DoubleQuoteStr(file) +" not found", ERR_FILE_NOT_FOUND));

   // [General]
   section = "General";
   string sAccount     = GetIniStringA(file, section, "Account", "");                                 // string Account = ICMarkets:12345678
   string sSymbol      = GetIniStringA(file, section, "Symbol",  "");                                 // string Symbol  = EURUSD
   string sThisAccount = GetAccountCompanyId() +":"+ GetAccountNumber();
   if (!StrCompareI(sAccount, sThisAccount)) return(!catch("ReadStatus(3)  "+ sequence.name +" account mis-match: "+ DoubleQuoteStr(sThisAccount) +" vs. "+ DoubleQuoteStr(sAccount) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_CONFIG_VALUE));
   if (!StrCompareI(sSymbol, Symbol()))      return(!catch("ReadStatus(4)  "+ sequence.name +" symbol mis-match: "+ Symbol() +" vs. "+ sSymbol +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_CONFIG_VALUE));

   // [Inputs]
   section = "Inputs";
   string sSequenceID            = GetIniStringA(file, section, "Sequence.ID",            "");        // string   Sequence.ID            = T1234
   string sGridDirection         = GetIniStringA(file, section, "GridDirection",          "");        // string   GridDirection          = Long
   string sGridVolatility        = GetIniStringA(file, section, "GridVolatility",         "");        // string   GridVolatility         = 30%
   string sGridVolatilityRange   = GetIniStringA(file, section, "GridVolatilityRange",    "");        // string   GridVolatilityRange    = ADR
   string sGridSize              = GetIniStringA(file, section, "GridSize",               "");        // string   GridSize               = 12.00
   string sUnitSize              = GetIniStringA(file, section, "UnitSize",               "");        // double   UnitSize               = 0.01
   int    iMaxUnits              = GetIniInt    (file, section, "MaxUnits"                  );        // int      MaxUnits               = 15
   string sPyramidMultiplier     = GetIniStringA(file, section, "Pyramid.Multiplier",     "");        // double   Pyramid.Multiplier     = 1.1
   string sMartingaleMultiplier  = GetIniStringA(file, section, "Martingale.Multiplier",  "");        // double   Martingale.Multiplier  = 1.1
   string sStopConditions        = GetIniStringA(file, section, "StopConditions",         "");        // string   StopConditions         = @profit(1%)
   string sShowProfitInPercent   = GetIniStringA(file, section, "ShowProfitInPercent",    "");        // bool     ShowProfitInPercent    = 1
   int    iSessionbreakStartTime = GetIniInt    (file, section, "Sessionbreak.StartTime"    );        // datetime Sessionbreak.StartTime = 86160 (23:56:30)
   int    iSessionbreakEndTime   = GetIniInt    (file, section, "Sessionbreak.EndTime"      );        // datetime Sessionbreak.EndTime   = 3730 (00:02:10)
   string sEaRecorder            = GetIniStringA(file, section, "EA.Recorder",            "");        // string   EA.Recorder            = 1,2,4

   if (!StrIsNumeric(sGridSize))             return(!catch("ReadStatus(5)  "+ sequence.name +" invalid input parameter GridSize "+ DoubleQuoteStr(sGridSize) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (!StrIsNumeric(sUnitSize))             return(!catch("ReadStatus(6)  "+ sequence.name +" invalid input parameter UnitSize "+ DoubleQuoteStr(sUnitSize) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (!StrIsNumeric(sPyramidMultiplier))    return(!catch("ReadStatus(7)  "+ sequence.name +" invalid input parameter Pyramid.Multiplier "+ DoubleQuoteStr(sPyramidMultiplier) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));
   if (!StrIsNumeric(sMartingaleMultiplier)) return(!catch("ReadStatus(8)  "+ sequence.name +" invalid input parameter Martingale.Multiplier "+ DoubleQuoteStr(sMartingaleMultiplier) +" in status file "+ DoubleQuoteStr(file), ERR_INVALID_FILE_FORMAT));

   Sequence.ID            = sSequenceID;
   GridDirection          = sGridDirection;
   GridVolatility         = sGridVolatility;
   GridSize               = sGridSize;
   UnitSize               = StrToDouble(sUnitSize);
   MaxUnits               = iMaxUnits;
   Pyramid.Multiplier     = StrToDouble(sPyramidMultiplier);
   Martingale.Multiplier  = StrToDouble(sMartingaleMultiplier);
   StopConditions         = sStopConditions;
   ShowProfitInPercent    = StrToBool(sShowProfitInPercent);
   Sessionbreak.StartTime = iSessionbreakStartTime;
   Sessionbreak.EndTime   = iSessionbreakEndTime;
   EA.Recorder            = sEaRecorder;

   // [Runtime status]
   section = "Runtime status";
   // sequence data
   sequence.id                 = GetIniInt    (file, section, "sequence.id"                );         // int      sequence.id                 = 1234
   sequence.created            = GetIniInt    (file, section, "sequence.created"           );         // datetime sequence.created            = 1624924800 (Mon, 2021.05.12 13:22:34)
   sequence.isTest             = GetIniBool   (file, section, "sequence.isTest"            );         // bool     sequence.isTest             = 1
   sequence.name               = GetIniStringA(file, section, "sequence.name",           "");         // string   sequence.name               = L.1234
   sequence.cycle              = GetIniInt    (file, section, "sequence.cycle"             );         // int      sequence.cycle              = 2
   sequence.status             = GetIniInt    (file, section, "sequence.status"            );         // int      sequence.status             = 1
   sequence.direction          = GetIniInt    (file, section, "sequence.direction"         );         // int      sequence.direction          = 2
   sequence.pyramidEnabled     = GetIniBool   (file, section, "sequence.pyramidEnabled"    );         // bool     sequence.pyramidEnabled     = 1
   sequence.martingaleEnabled  = GetIniBool   (file, section, "sequence.martingaleEnabled" );         // bool     sequence.martingaleEnabled  = 0
   sequence.gridsize           = GetIniDouble (file, section, "sequence.gridsize"          );         // double   sequence.gridsize           = 3.5
   sequence.unitsize           = GetIniDouble (file, section, "sequence.unitsize"          );         // double   sequence.unitsize           = 0.01
   sequence.gridvola           = GetIniDouble (file, section, "sequence.gridvola"          );         // double   sequence.gridvola           = 29.5
   sequence.gridbase           = GetIniDouble (file, section, "sequence.gridbase"          );         // double   sequence.gridbase           = 1.17453
   sequence.startTime          = GetIniInt    (file, section, "sequence.startTime"         );         // datetime sequence.startTime          = 1624924801 (Mon, 2021.05.12 13:25:12)
   sequence.startPrice         = GetIniDouble (file, section, "sequence.startPrice"        );         // double   sequence.startPrice         = 1.17453
   sequence.startEquity        = GetIniDouble (file, section, "sequence.startEquity"       );         // double   sequence.startEquity        = 1000.00
   sequence.stopTime           = GetIniInt    (file, section, "sequence.stopTime"          );         // datetime sequence.stopTime           = 1624924802 (Mon, 2021.05.12 17:01:27)
   sequence.stopPrice          = GetIniDouble (file, section, "sequence.stopPrice"         );         // double   sequence.stopPrice          = 1.17453
   sequence.openLots           = GetIniDouble (file, section, "sequence.openLots"          );         // double   sequence.openLots           = 0.12
   sequence.avgOpenPrice       = GetIniDouble (file, section, "sequence.avgOpenPrice"      );         // double   sequence.avgOpenPrice       = 1.17453
   sequence.floatingCommission = GetIniDouble (file, section, "sequence.floatingCommission");         // double   sequence.floatingCommission = 12.34
   sequence.floatingSwap       = GetIniDouble (file, section, "sequence.floatingSwap"      );         // double   sequence.floatingSwap       = 23.45
   sequence.floatingPL         = GetIniDouble (file, section, "sequence.floatingPL"        );         // double   sequence.floatingPL         = 12.34
   sequence.hedgedPL           = GetIniDouble (file, section, "sequence.hedgedPL"          );         // double   sequence.hedgedPL           = 34.56
   sequence.openPL             = GetIniDouble (file, section, "sequence.openPL"            );         // double   sequence.openPL             = 23.45
   sequence.closedPL           = GetIniDouble (file, section, "sequence.closedPL"          );         // double   sequence.closedPL           = 45.67
   sequence.totalPL            = GetIniDouble (file, section, "sequence.totalPL"           );         // double   sequence.totalPL            = 123.45
   sequence.maxProfit          = GetIniDouble (file, section, "sequence.maxProfit"         );         // double   sequence.maxProfit          = 23.45
   sequence.maxDrawdown        = GetIniDouble (file, section, "sequence.maxDrawdown"       );         // double   sequence.maxDrawdown        = -11.23
   sequence.tpPrice            = GetIniDouble (file, section, "sequence.tpPrice"           );         // double   sequence.tpPrice            = 1.17692
   sequence.slPrice            = GetIniDouble (file, section, "sequence.slPrice"           );         // double   sequence.slPrice            = 1.17051
   SS.SequenceName();

   // long order data
   ResetOrderLog(D_LONG);
   long.enabled                = GetIniBool   (file, section, "long.enabled"          );              // bool     long.enabled  = 1
   long.openLots               = GetIniDouble (file, section, "long.openLots"         );              // double   long.openLots = 0.02
   long.slippage               = GetIniDouble (file, section, "long.slippage"         );              // double   long.slippage = 0
   long.openPL                 = GetIniDouble (file, section, "long.openPL"           );              // double   long.openPL   = 12.34
   long.closedPL               = GetIniDouble (file, section, "long.closedPL"         );              // double   long.closedPL = 23.34
   long.bePrice                = GetIniDouble (file, section, "long.bePrice"          );              // double   long.bePrice  = 1.17453
   long.minLevel               = GetIniInt    (file, section, "long.minLevel", INT_MAX);              // int      long.minLevel = -2
   long.maxLevel               = GetIniInt    (file, section, "long.maxLevel", INT_MIN);              // int      long.maxLevel = 7
   string sKeys[], sOrder="";
   int size = ReadStatus.OrderKeys(file, section, MODE_TRADES, D_LONG, sKeys); if (size < 0) return(false);
   for (int i=0; i < size; i++) {
      sOrder = GetIniStringA(file, section, sKeys[i], "");                                            // long.orders.{i} = {data}
      if (!ReadStatus.ParseOrder(sKeys[i], sOrder)) return(!catch("ReadStatus(9)  "+ sequence.name +" invalid order record in status file "+ DoubleQuoteStr(file) + NL + sKeys[i] +"="+ sOrder, ERR_INVALID_FILE_FORMAT));
   }
   size = ReadStatus.OrderKeys(file, section, MODE_HISTORY, D_LONG, sKeys); if (size < 0) return(false);
   for (i=0; i < size; i++) {
      sOrder = GetIniStringA(file, section, sKeys[i], "");                                            // long.history.{i} = {data}
      if (!ReadStatus.ParseOrder(sKeys[i], sOrder)) return(!catch("ReadStatus(10)  "+ sequence.name +" invalid history record in status file "+ DoubleQuoteStr(file) + NL + sKeys[i] +"="+ sOrder, ERR_INVALID_FILE_FORMAT));
   }

   // short order data
   ResetOrderLog(D_SHORT);
   short.enabled               = GetIniBool   (file, section, "short.enabled"          );             // bool     short.enabled  = 1
   short.openLots              = GetIniDouble (file, section, "short.openLots"         );             // double   short.openLots = 0.02
   short.slippage              = GetIniDouble (file, section, "short.slippage"         );             // double   short.slippage = 0
   short.openPL                = GetIniDouble (file, section, "short.openPL"           );             // double   short.openPL   = 12.34
   short.closedPL              = GetIniDouble (file, section, "short.closedPL"         );             // double   short.closedPL = 23.34
   short.bePrice               = GetIniDouble (file, section, "short.bePrice"          );             // double   short.bePrice  = 1.17453
   short.minLevel              = GetIniInt    (file, section, "short.minLevel", INT_MAX);             // int      short.minLevel = -2
   short.maxLevel              = GetIniInt    (file, section, "short.maxLevel", INT_MIN);             // int      short.maxLevel = 7
   size = ReadStatus.OrderKeys(file, section, MODE_TRADES, D_SHORT, sKeys); if (size < 0) return(false);
   for (i=0; i < size; i++) {
      sOrder = GetIniStringA(file, section, sKeys[i], "");                                            // short.orders.{i} = {data}
      if (!ReadStatus.ParseOrder(sKeys[i], sOrder)) return(!catch("ReadStatus(11)  "+ sequence.name +" invalid order record in status file "+ DoubleQuoteStr(file) + NL + sKeys[i] +"="+ sOrder, ERR_INVALID_FILE_FORMAT));
   }
   size = ReadStatus.OrderKeys(file, section, MODE_HISTORY, D_SHORT, sKeys); if (size < 0) return(false);
   for (i=0; i < size; i++) {
      sOrder = GetIniStringA(file, section, sKeys[i], "");                                            // short.history.{i} = {data}
      if (!ReadStatus.ParseOrder(sKeys[i], sOrder)) return(!catch("ReadStatus(12)  "+ sequence.name +" invalid history record in status file "+ DoubleQuoteStr(file) + NL + sKeys[i] +"="+ sOrder, ERR_INVALID_FILE_FORMAT));
   }

   // other
   stop.price.condition        = GetIniBool   (file, section, "stop.price.condition"      );          // bool     stop.price.condition       = 1
   stop.price.type             = GetIniInt    (file, section, "stop.price.type"           );          // int      stop.price.type            = 4
   stop.price.value            = GetIniDouble (file, section, "stop.price.value"          );          // double   stop.price.value           = 1.17453
   stop.price.lastValue        = GetIniDouble (file, section, "stop.price.lastValue"      );          // double   stop.price.lastValue       = 0
   stop.price.description      = GetIniStringA(file, section, "stop.price.description", "");          // string   stop.price.description     = text

   stop.profitAbs.condition    = GetIniBool   (file, section, "stop.profitAbs.condition"        );    // bool     stop.profitAbs.condition   = 1
   stop.profitAbs.value        = GetIniDouble (file, section, "stop.profitAbs.value"            );    // double   stop.profitAbs.value       = 10.00
   stop.profitAbs.description  = GetIniStringA(file, section, "stop.profitAbs.description",   "");    // string   stop.profitAbs.description = text
   stop.profitPct.condition    = GetIniBool   (file, section, "stop.profitPct.condition"        );    // bool     stop.profitPct.condition   = 0
   stop.profitPct.value        = GetIniDouble (file, section, "stop.profitPct.value"            );    // double   stop.profitPct.value       = 0
   stop.profitPct.absValue     = GetIniDouble (file, section, "stop.profitPct.absValue", INT_MAX);    // double   stop.profitPct.absValue    = 0.00
   stop.profitPct.description  = GetIniStringA(file, section, "stop.profitPct.description",   "");    // string   stop.profitPct.description = text

   stop.lossAbs.condition      = GetIniBool   (file, section, "stop.lossAbs.condition"        );      // bool     stop.lossAbs.condition     = 1
   stop.lossAbs.value          = GetIniDouble (file, section, "stop.lossAbs.value"            );      // double   stop.lossAbs.value         = -20.00
   stop.lossAbs.description    = GetIniStringA(file, section, "stop.lossAbs.description",   "");      // string   stop.lossAbs.description   = text
   stop.lossPct.condition      = GetIniBool   (file, section, "stop.lossPct.condition"        );      // bool     stop.lossPct.condition     = 0
   stop.lossPct.value          = GetIniDouble (file, section, "stop.lossPct.value"            );      // double   stop.lossPct.value         = 0
   stop.lossPct.absValue       = GetIniDouble (file, section, "stop.lossPct.absValue", INT_MIN);      // double   stop.lossPct.absValue      = 0.00
   stop.lossPct.description    = GetIniStringA(file, section, "stop.lossPct.description",   "");      // string   stop.lossPct.description   = text

   sessionbreak.starttime      = GetIniInt    (file, section, "sessionbreak.starttime");              // datetime sessionbreak.starttime = 1583254806 (Mon, 2021.05.12 23:56:30)
   sessionbreak.endtime        = GetIniInt    (file, section, "sessionbreak.endtime"  );              // datetime sessionbreak.endtime   = 1583254807 (Tue, 2021.05.13 00:02:10)

   return(!catch("ReadStatus(13)"));
}


/**
 * Read and return the keys of the specified order records found in the status file (sorting order doesn't matter).
 *
 * @param  _In_  string file      - status filename
 * @param  _In_  string section   - status section
 * @param  _In_  int    type      - record type to read: MODE_TRADES | MODE_HISTORY
 * @param  _In_  int    direction - order direction to read: D_LONG | D_SHORT
 * @param  _Out_ string &keys[]   - array receiving the found keys
 *
 * @return int - number of found keys or EMPTY (-1) in case of errors
 */
int ReadStatus.OrderKeys(string file, string section, int type, int direction, string &keys[]) {
   if (type!=MODE_TRADES && type!=MODE_HISTORY) return(_EMPTY(catch("ReadStatus.OrderKeys(1)  "+ sequence.name +" invalid parameter type: "+ type, ERR_INVALID_PARAMETER)));
   if (direction!=D_LONG && direction!=D_SHORT) return(_EMPTY(catch("ReadStatus.OrderKeys(2)  "+ sequence.name +" invalid parameter direction: "+ direction, ERR_INVALID_PARAMETER)));

   int size = GetIniKeys(file, section, keys);
   if (size < 0) return(EMPTY);

   string prefix = ifString(direction==D_LONG, "long.", "short.") + ifString(type==MODE_TRADES, "orders.", "history.");

   for (int i=size-1; i >= 0; i--) {
      if (StrStartsWithI(keys[i], prefix))
         continue;
      ArraySpliceStrings(keys, i, 1);     // drop all non-order keys
      size--;
   }
   return(size);                          // no need to sort as records are inserted at the correct position
}


/**
 * Parse the string representation of an order/history record and store the parsed data.
 *
 * @param  string key   - order key
 * @param  string value - order string to parse
 *
 * @return bool - success status
 */
bool ReadStatus.ParseOrder(string key, string value) {
   if (IsLastError()) return(false);

   if      (StrContainsI(key, ".orders.")) int pool = MODE_TRADES;
   else if (StrContainsI(key, ".history."))    pool = MODE_HISTORY;
   else return(!catch("ReadStatus.ParseOrder(1)  "+ sequence.name +" illegal order record key "+ DoubleQuoteStr(key), ERR_INVALID_FILE_FORMAT));

   if      (StrStartsWithI(key, "long.")) int direction = D_LONG;
   else if (StrStartsWithI(key, "short."))    direction = D_SHORT;
   else return(!catch("ReadStatus.ParseOrder(2)  "+ sequence.name +" illegal order record key "+ DoubleQuoteStr(key), ERR_INVALID_FILE_FORMAT));

   string values[];

   if (pool == MODE_TRADES) {
      // [long|short].orders.i=ticket,level,lots,pendingType,pendingTime,pendingPrice,openType,openTime,openPrice,closeTime,closePrice,swap,commission,profit
      if (Explode(value, ",", values, NULL) != 14) return(!catch("ReadStatus.ParseOrder(3)  "+ sequence.name +" illegal number of details ("+ ArraySize(values) +") in order record", ERR_INVALID_FILE_FORMAT));
      int      ticket       = StrToInteger(StrTrim(values[ 0]));     // int      ticket
      int      level        = StrToInteger(StrTrim(values[ 1]));     // int      level
      double   lots         =  StrToDouble(StrTrim(values[ 2]));     // double   lots
      int      pendingType  = StrToInteger(StrTrim(values[ 3]));     // int      pendingType
      datetime pendingTime  = StrToInteger(StrTrim(values[ 4]));     // datetime pendingTime
      double   pendingPrice =  StrToDouble(StrTrim(values[ 5]));     // double   pendingPrice
      int      openType     = StrToInteger(StrTrim(values[ 6]));     // int      openType
      datetime openTime     = StrToInteger(StrTrim(values[ 7]));     // datetime openTime
      double   openPrice    =  StrToDouble(StrTrim(values[ 8]));     // double   openPrice
      datetime closeTime    = StrToInteger(StrTrim(values[ 9]));     // datetime closeTime
      double   closePrice   =  StrToDouble(StrTrim(values[10]));     // double   closePrice
      double   swap         =  StrToDouble(StrTrim(values[11]));     // double   swap
      double   commission   =  StrToDouble(StrTrim(values[12]));     // double   commission
      double   profit       =  StrToDouble(StrTrim(values[13]));     // double   profit
      return(!IsEmpty(Orders.AddRecord(direction, ticket, level, lots, pendingType, pendingTime, pendingPrice, openType, openTime, openPrice, closeTime, closePrice, swap, commission, profit)));
   }

   if (pool == MODE_HISTORY) {
      // [long|short].history.i=cycle,startTime,startPrice,gridbase,stopTime,stopPrice,totalProfit,maxProfit,maxDrawdown,ticket,level,lots,pendingType,pendingTime,pendingPrice,openType,openTime,openPrice,closeTime,closePrice,swap,commission,profit
      string sId = StrRightFrom(key, ".", -1); if (!StrIsDigits(sId))       return(!catch("ReadStatus.ParseOrder(4)  "+ sequence.name +" illegal history record key "+ DoubleQuoteStr(key), ERR_INVALID_FILE_FORMAT));
      int index = StrToInteger(sId);
      if (Explode(value, ",", values, NULL) != ArrayRange(long.history, 1)) return(!catch("ReadStatus.ParseOrder(5)  "+ sequence.name +" illegal number of details ("+ ArraySize(values) +") in history record", ERR_INVALID_FILE_FORMAT));

      int      cycle        = StrToInteger(values[HI_CYCLE       ]);
      datetime startTime    = StrToInteger(values[HI_STARTTIME   ]);
      double   startPrice   =  StrToDouble(values[HI_STARTPRICE  ]);
      double   gridbase     =  StrToDouble(values[HI_GRIDBASE    ]);
      datetime stopTime     = StrToInteger(values[HI_STOPTIME    ]);
      double   stopPrice    =  StrToDouble(values[HI_STOPPRICE   ]);
      double   totalProfit  =  StrToDouble(values[HI_TOTALPROFIT ]);
      double   maxProfit    =  StrToDouble(values[HI_MAXPROFIT   ]);
      double   maxDrawdown  =  StrToDouble(values[HI_MAXDRAWDOWN ]);
               ticket       = StrToInteger(values[HI_TICKET      ]);
               level        = StrToInteger(values[HI_LEVEL       ]);
               lots         =  StrToDouble(values[HI_LOTS        ]);
               pendingType  = StrToInteger(values[HI_PENDINGTYPE ]);
               pendingTime  = StrToInteger(values[HI_PENDINGTIME ]);
               pendingPrice =  StrToDouble(values[HI_PENDINGPRICE]);
               openType     = StrToInteger(values[HI_OPENTYPE    ]);
               openTime     = StrToInteger(values[HI_OPENTIME    ]);
               openPrice    =  StrToDouble(values[HI_OPENPRICE   ]);
               closeTime    = StrToInteger(values[HI_CLOSETIME   ]);
               closePrice   =  StrToDouble(values[HI_CLOSEPRICE  ]);
               swap         =  StrToDouble(values[HI_SWAP        ]);
               commission   =  StrToDouble(values[HI_COMMISSION  ]);
               profit       =  StrToDouble(values[HI_PROFIT      ]);
      return(History.AddRecord(direction, index, cycle, gridbase, startTime, startPrice, stopTime, stopPrice, totalProfit, maxProfit, maxDrawdown, ticket, level, lots, pendingType, pendingTime, pendingPrice, openType, openTime, openPrice, closeTime, closePrice, swap, commission, profit));
   }
}


/**
 * Store the current sequence id in the terminal (for template changes, terminal restart, recompilation etc).
 *
 * @return bool - success status
 */
bool StoreSequenceId() {
   string name = ProgramName() +".Sequence.ID";
   string value = ifString(sequence.isTest, "T", "") + sequence.id;

   Sequence.ID = value;                                              // store in input parameter

   if (__isChart) {
      Chart.StoreString(name, value);                                // store in chart
      SetWindowStringA(__ExecutionContext[EC.hChart], name, value);  // store in chart window
   }
   return(!catch("StoreSequenceId(1)"));
}


/**
 * Find and restore a stored sequence id (for template changes, terminal restart, recompilation etc).
 *
 * @return bool - whether a sequence id was successfully restored
 */
bool RestoreSequenceId() {
   bool isError, muteErrors=false;

   // check input parameter
   string value = Sequence.ID;
   if (ApplySequenceId(value, muteErrors, "RestoreSequenceId(1)")) return(true);
   isError = muteErrors;
   if (isError) return(false);

   if (__isChart) {
      // check chart window
      string name = ProgramName() +".Sequence.ID";
      value = GetWindowStringA(__ExecutionContext[EC.hChart], name);
      muteErrors = false;
      if (ApplySequenceId(value, muteErrors, "RestoreSequenceId(2)")) return(true);
      isError = muteErrors;
      if (isError) return(false);

      // check chart
      if (Chart.RestoreString(name, value, false)) {
         muteErrors = false;
         if (ApplySequenceId(value, muteErrors, "RestoreSequenceId(3)")) return(true);
      }
   }
   return(false);
}


/**
 * Remove a stored sequence id.
 *
 * @return bool - success status
 */
bool RemoveSequenceId() {
   if (__isChart) {
      // chart window
      string name = ProgramName() +".Sequence.ID";
      RemoveWindowStringA(__ExecutionContext[EC.hChart], name);

      // chart
      Chart.RestoreString(name, name, true);

      // remove a chart status for chart commands
      name = "EA.status";
      if (ObjectFind(name) != -1) ObjectDelete(name);
   }
   return(!catch("RemoveSequenceId(1)"));
}



/**
 * Parse and apply the passed sequence id value (format: /T?[0-9]{4}/).
 *
 * @param  _In_    string value  - stringyfied sequence id
 * @param  _InOut_ bool   error  - in:  whether to mute a parse error (TRUE) or to trigger a fatal error (FALSE)
 *                                 out: whether a parsing error occurred (stored in last_error)
 * @param  _In_    string caller - caller identification (for error messages)
 *
 * @return bool - whether the sequence id was successfully applied
 */
bool ApplySequenceId(string value, bool &error, string caller) {
   string valueBak = value;
   bool muteErrors = error!=0;
   error = false;

   value = StrTrim(value);
   if (!StringLen(value)) return(false);

   bool isTest = false;
   int sequenceId = 0;

   if (StrStartsWith(value, "T")) {
      isTest = true;
      value = StrSubstr(value, 1);
   }

   if (!StrIsDigits(value)) {
      error = true;
      if (muteErrors) return(!SetLastError(ERR_INVALID_PARAMETER));
      return(!catch(caller +"->ApplySequenceId(1)  invalid sequence id value: \""+ valueBak +"\" (must be digits only)", ERR_INVALID_PARAMETER));
   }

   int iValue = StrToInteger(value);
   if (iValue < SID_MIN || iValue > SID_MAX) {
      error = true;
      if (muteErrors) return(!SetLastError(ERR_INVALID_PARAMETER));
      return(!catch(caller +"->ApplySequenceId(2)  invalid sequence id value: \""+ valueBak +"\" (range error)", ERR_INVALID_PARAMETER));
   }

   sequence.isTest = isTest;
   sequence.id     = iValue;
   Sequence.ID     = ifString(IsTestSequence(), "T", "") + sequence.id;
   SS.SequenceName();
   return(true);
}


/**
 * Return a description of a sequence status code.
 *
 * @param  int status
 *
 * @return string - description or an empty string in case of errors
 */
string StatusDescription(int status) {
   switch (status) {
      case STATUS_UNDEFINED  : return("undefined"  );
      case STATUS_WAITING    : return("waiting"    );
      case STATUS_PROGRESSING: return("progressing");
      case STATUS_STOPPED    : return("stopped"    );
   }
   return(_EMPTY_STR(catch("StatusDescription(1)  "+ sequence.name +" invalid parameter status: "+ status, ERR_INVALID_PARAMETER)));
}


/**
 * Return a readable version of a sequence status code.
 *
 * @param  int status
 *
 * @return string
 */
string StatusToStr(int status) {
   switch (status) {
      case STATUS_UNDEFINED  : return("STATUS_UNDEFINED"  );
      case STATUS_WAITING    : return("STATUS_WAITING"    );
      case STATUS_PROGRESSING: return("STATUS_PROGRESSING");
      case STATUS_STOPPED    : return("STATUS_STOPPED"    );
   }
   return(_EMPTY_STR(catch("StatusToStr(1)  "+ sequence.name +" invalid parameter status: "+ status, ERR_INVALID_PARAMETER)));
}


/**
 * Display the current runtime status.
 *
 * @param  int error [optional] - error to display (default: none)
 *
 * @return int - the same error or the current error status if no error was passed
 */
int ShowStatus(int error = NO_ERROR) {
   if (!__isChart) return(error);

   static bool isRecursion = false;                   // to prevent recursive calls a specified error is displayed only once
   if (error != 0) {
      if (isRecursion) return(error);
      isRecursion = true;
   }
   string sSequence="", sDirection="", sError="";

   switch (sequence.direction) {
      case D_LONG:  sDirection = "Long";       break;
      case D_SHORT: sDirection = "Short";      break;
      case D_BOTH:  sDirection = "Long+Short"; break;
   }

   switch (sequence.status) {
      case STATUS_UNDEFINED:   sSequence = "not initialized";                                                 break;
      case STATUS_WAITING:     sSequence = StringConcatenate(sDirection, "  ", sequence.id, "  waiting");     break;
      case STATUS_PROGRESSING: sSequence = StringConcatenate(sDirection, "  ", sequence.id, "  progressing"); break;
      case STATUS_STOPPED:     sSequence = StringConcatenate(sDirection, "  ", sequence.id, "  stopped");     break;
      default:
         return(catch("ShowStatus(1)  "+ sequence.name +" illegal sequence status: "+ sequence.status, ERR_ILLEGAL_STATE));
   }
   if (__STATUS_OFF) sError = StringConcatenate("  [switched off => ", ErrorDescription(__STATUS_OFF.reason), "]");

   string msg = StringConcatenate(ProgramName(), "           ", sSequence, sError,              NL,
                                                                                                NL,
                                  "Grid:          ",  sGridParameters,                          NL,
                                  "Volatility:   ",   sGridVolatility,                          NL,
                                                                                                NL,
                                  "Long:         ",   sOpenLongLots,                            NL,
                                  "Short:        ",   sOpenShortLots,                           NL,
                                  "Total:         ",  sTotalLots,                               NL,
                                                                                                NL,
                                  "Stop:          ",  sStopConditions,                          NL,
                                  "BE:             ", sSequenceBePrice,                         NL,
                                  "TP:             ", sSequenceTpPrice,                         NL,
                                  "SL:             ", sSequenceSlPrice,                         NL,
                                                                                                NL,
                                  "Profit:        ",  sSequenceTotalPL, "  ", sSequencePlStats, NL,
                                   sCycleStats
   );

   // 3 lines margin-top for instrument and indicator legends
   Comment(NL, NL, NL, NL, msg);
   if (__CoreFunction == CF_INIT) WindowRedraw();

   // store status in the chart to enable sending of chart commands
   string label = "EA.status";
   if (ObjectFind(label) != 0) {
      ObjectCreate(label, OBJ_LABEL, 0, 0, 0);
      ObjectSet(label, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   }
   ObjectSetText(label, StringConcatenate(Sequence.ID, "|", StatusDescription(sequence.status)));

   error = intOr(catch("ShowStatus(2)"), error);
   isRecursion = false;
   return(error);
}


/**
 * ShowStatus: Update all string representations.
 */
void SS.All() {
   if (__isChart) {
      SS.SequenceName();
      SS.GridParameters();
      SS.Lots();
      SS.StopConditions();
      SS.Targets();
      SS.TotalPL();
      SS.PLStats();
      SS.CycleStats();
   }
}


/**
 * ShowStatus: Update the string representations of grid parameters and volatility.
 */
void SS.GridParameters() {
   if (__isChart) {
      string sGridSize = "";
      if      (!sequence.gridsize)         sGridSize = "?";
      else if (Digits==2 && Close[0]>=500) sGridSize = NumberToStr(sequence.gridsize/100, ",'R.2");      // 123 pip => 1.23
      else                                 sGridSize = NumberToStr(sequence.gridsize, ".+") +" pip";     // 12.3 pip

      string sUnitSize   = ifString(!sequence.unitsize, "?", NumberToStr(sequence.unitsize, ".+") +" lot");
      string sPyramid    = ifString(sequence.pyramidEnabled,    "    Pyramid="+    NumberToStr(Pyramid.Multiplier,    ".+"), "");
      string sMartingale = ifString(sequence.martingaleEnabled, "    Martingale="+ NumberToStr(Martingale.Multiplier, ".+"), "");

      sGridParameters = sGridSize +" x "+ sUnitSize + sPyramid + sMartingale;
      sGridVolatility = ifString(!sequence.gridvola, "?", NumberToStr(NormalizeDouble(sequence.gridvola, 1), ".+") +"%/ADR");
   }
}


/**
 * ShowStatus: Update the string representation of "long.totalLots", "short.totalLots" and "sequence.totalLots".
 */
void SS.Lots() {
   if (__isChart) {
      string sOpenLevels="", sMinusLevels="", sMax="", sSlippage="";
      int plusLevels, minusLevels, openLevels;

      if (!long.openLots) sOpenLongLots = "-";
      else {
         plusLevels  = Max(0, long.maxLevel);
         minusLevels = -Min(0, long.minLevel);
         if (plusLevels && minusLevels) minusLevels--;
         openLevels  = plusLevels + minusLevels;
         sOpenLevels = "levels: "+ openLevels;

         if ((plusLevels && minusLevels) || (openLevels >= MaxUnits)) {
            if (plusLevels && minusLevels)   sMinusLevels = "-"+ minusLevels;
            if (openLevels >= MaxUnits) sMax = ifString(plusLevels && minusLevels, ", ", "") + "max";
            sOpenLevels = "levels: "+ openLevels +" ("+ sMinusLevels + sMax +")";
         }

         sSlippage = PipToStr(long.slippage/Pip, true, true);
         if (GT(long.slippage, 0)) sSlippage = "+"+ sSlippage;

         sOpenLongLots = NumberToStr(long.openLots, "+.+") +" lot    "+ sOpenLevels + ifString(!long.slippage, "", "    slippage: "+ sSlippage);
      }

      if (!short.openLots) sOpenShortLots = "-";
      else {
         plusLevels  = Max(0, short.maxLevel);
         minusLevels = -Min(0, short.minLevel);
         if (plusLevels && minusLevels) minusLevels--;
         openLevels  = plusLevels + minusLevels;
         sOpenLevels = "levels: "+ openLevels;

         if ((plusLevels && minusLevels) || (openLevels >= MaxUnits)) {
            if (plusLevels && minusLevels)   sMinusLevels = "-"+ minusLevels;
            if (openLevels >= MaxUnits) sMax = ifString(plusLevels && minusLevels, ", ", "") + "max";
            sOpenLevels = "levels: "+ openLevels +" ("+ sMinusLevels + sMax +")";
         }

         sSlippage = PipToStr(short.slippage/Pip, true, true);
         if (GT(short.slippage, 0)) sSlippage = "+"+ sSlippage;

         sOpenShortLots = NumberToStr(-short.openLots, "+.+") +" lot    "+ sOpenLevels + ifString(!short.slippage, "", "    slippage: "+ sSlippage);
      }

      if (!long.openLots && !short.openLots) sTotalLots = "-";
      else if (!sequence.openLots)           sTotalLots = "�0 (hedged)";
      else                                   sTotalLots = NumberToStr(sequence.openLots, "+.+") +" lot";
   }
}


/**
 * ShowStatus: Update the string representation of "sequence.totalPL".
 *
 * @param  bool enforce [optional] - whether to perform the update unconditionally (default: no)
 */
void SS.TotalPL(bool enforce = false) {
   if (__isChart || enforce) {
      // not before a positions was opened
      if (!ArraySize(long.ticket) && !ArraySize(short.ticket)) sSequenceTotalPL = "-";
      else if (ShowProfitInPercent)                            sSequenceTotalPL = NumberToStr(MathDiv(sequence.totalPL, sequence.startEquity) * 100, "+.2") +"%";
      else                                                     sSequenceTotalPL = NumberToStr(sequence.totalPL, "+.2");
   }
}


/**
 * ShowStatus: Update the string representaton of the PL statistics.
 *
 * @param  bool enforce [optional] - whether to perform the update unconditionally (default: no)
 */
void SS.PLStats(bool enforce = false) {
   if (__isChart || enforce) {
      // not before a positions was opened
      if (!ArraySize(long.ticket) && !ArraySize(short.ticket)) {
         sSequencePlStats = "";
      }
      else {
         string sSequenceMaxProfit="", sSequenceMaxDrawdown="";
         if (ShowProfitInPercent) {
            sSequenceMaxProfit   = NumberToStr(MathDiv(sequence.maxProfit, sequence.startEquity) * 100, "+.2") +"%";
            sSequenceMaxDrawdown = NumberToStr(MathDiv(sequence.maxDrawdown, sequence.startEquity) * 100, "+.2") +"%";
         }
         else {
            sSequenceMaxProfit   = NumberToStr(sequence.maxProfit, "+.2");
            sSequenceMaxDrawdown = NumberToStr(sequence.maxDrawdown, "+.2");
         }
         sSequencePlStats = StringConcatenate("(", sSequenceMaxProfit, " / ", sSequenceMaxDrawdown, ")");
      }
   }
}


/**
 * ShowStatus: Update the string representation of PL stats of finished sequence cycles.
 */
void SS.CycleStats() {
   if (!__isChart) return;

   sCycleStats = "";

   double history[][23];               // must match global vars long/short.history[][]
   if      (long.enabled  && ArraySize(long.history))  ArrayCopy(history, long.history);
   else if (short.enabled && ArraySize(short.history)) ArrayCopy(history, short.history);
   else return;

   string sTotalPL="", sMaxProfit="", sMaxDrawdown="", sResult="";
   int size=ArrayRange(history, 0), lastCycle=0;

   for (int i=0; i < size; i++) {
      int cycle = history[i][HI_CYCLE];

      if (cycle != lastCycle) {
         double totalPL     = history[i][HI_TOTALPROFIT];
         double maxProfit   = history[i][HI_MAXPROFIT  ];
         double maxDrawdown = history[i][HI_MAXDRAWDOWN];

         if (ShowProfitInPercent) {
            sTotalPL     = NumberToStr(MathDiv(totalPL,     sequence.startEquity) * 100, "+.2") +"%";
            sMaxProfit   = NumberToStr(MathDiv(maxProfit,   sequence.startEquity) * 100, "+.2") +"%";
            sMaxDrawdown = NumberToStr(MathDiv(maxDrawdown, sequence.startEquity) * 100, "+.2") +"%";
         }
         else {
            sTotalPL     = NumberToStr(sequence.totalPL, "+.2");
            sMaxProfit   = NumberToStr(maxProfit,        "+.2");
            sMaxDrawdown = NumberToStr(maxDrawdown,      "+.2");
         }
         sResult = StringConcatenate(cycle, ":  ", sTotalPL, "  (", sMaxProfit, " / ", sMaxDrawdown, ")", NL, sResult);
         lastCycle = cycle;
      }
   }
   if (lastCycle > 0) sCycleStats = StringConcatenate("-------------------------------------------------", NL, sResult);

   ArrayResize(history, 0);
}


/**
 * ShowStatus: Update the string representation of "long/short.bePrice", "sequence.tpPrice" and "sequence.slPrice".
 */
void SS.Targets() {
   if (__isChart) {
      sSequenceBePrice = "";
      if (long.enabled) {
         if (!long.bePrice)              sSequenceBePrice = sSequenceBePrice +"-";
         else                            sSequenceBePrice = sSequenceBePrice + NumberToStr(RoundCeil(long.bePrice, Digits), PriceFormat);
      }
      if (long.enabled && short.enabled) sSequenceBePrice = sSequenceBePrice +" / ";
      if (short.enabled) {
         if (!short.bePrice)             sSequenceBePrice = sSequenceBePrice +"-";
         else                            sSequenceBePrice = sSequenceBePrice + NumberToStr(RoundFloor(short.bePrice, Digits), PriceFormat);
      }

      if      (!sequence.tpPrice)     sSequenceTpPrice = "";
      else if (sequence.openLots > 0) sSequenceTpPrice = NumberToStr(RoundCeil(sequence.tpPrice, Digits), PriceFormat);
      else                            sSequenceTpPrice = NumberToStr(RoundFloor(sequence.tpPrice, Digits), PriceFormat);

      if      (!sequence.slPrice)     sSequenceSlPrice = "";
      else if (sequence.openLots > 0) sSequenceSlPrice = NumberToStr(RoundFloor(sequence.slPrice, Digits), PriceFormat);
      else                            sSequenceSlPrice = NumberToStr(RoundCeil(sequence.slPrice, Digits), PriceFormat);
   }
}


/**
 * ShowStatus: Update the string representations of standard and long sequence name.
 */
void SS.SequenceName() {
   sequence.name = "";
   if (sequence.direction & D_LONG  && 1) sequence.name = sequence.name +"L";   // don't query 'long/short.enabled' as it gets assigned way later
   if (sequence.direction & D_SHORT && 1) sequence.name = sequence.name +"S";
   sequence.name = sequence.name +"."+ sequence.id;
}


/**
 * ShowStatus: Update the string representation of the configured stop conditions.
 */
void SS.StopConditions() {
   if (__isChart) {
      string sValue = "";

      // order: profit, loss, price
      if (stop.profitAbs.description != "") {
         sValue = sValue + ifString(sValue=="", "", " | ") + ifString(stop.profitAbs.condition, "@", "!") + stop.profitAbs.description;
      }
      if (stop.profitPct.description != "") {
         sValue = sValue + ifString(sValue=="", "", " | ") + ifString(stop.profitPct.condition, "@", "!") + stop.profitPct.description;
      }
      if (stop.lossAbs.description != "") {
         sValue = sValue + ifString(sValue=="", "", " | ") + ifString(stop.lossAbs.condition, "@", "!") + stop.lossAbs.description;
      }
      if (stop.lossPct.description != "") {
         sValue = sValue + ifString(sValue=="", "", " | ") + ifString(stop.lossPct.condition, "@", "!") + stop.lossPct.description;
      }
      if (stop.price.description != "") {
         sValue = sValue + ifString(sValue=="", "", " | ") + ifString(stop.price.condition, "@", "!") + stop.price.description;
      }
      if (sValue == "") sStopConditions = "-";
      else              sStopConditions = sValue;
   }
}


/**
 * Create the status display box. It consists of overlapping rectangles made of font "Webdings", char "g".
 * Called from onInit() only.
 *
 * @return bool - success status
 */
bool CreateStatusBox() {
   if (!__isChart) return(true);

   int x[]={2, 114}, y=58, fontSize=115, rectangles=ArraySize(x);
   color  bgColor = LemonChiffon;
   string label = "";

   for (int i=0; i < rectangles; i++) {
      label = ProgramName() +".statusbox."+ (i+1);
      if (ObjectFind(label) == -1) if (!ObjectCreateRegister(label, OBJ_LABEL, 0, 0, 0, 0, 0, 0, 0)) return(false);
      ObjectSet(label, OBJPROP_CORNER, CORNER_TOP_LEFT);
      ObjectSet(label, OBJPROP_XDISTANCE, x[i]);
      ObjectSet(label, OBJPROP_YDISTANCE, y);
      ObjectSetText(label, "g", fontSize, "Webdings", bgColor);
   }
   return(!catch("CreateStatusBox(1)"));
}


/**
 * Create a screenshot of the running sequence and store it next to the status file.
 *
 * @param  string comment [optional] - additional comment to append to the filename (default: none)
 *
 * @return bool - success status
 */
bool MakeScreenshot(string comment = "") {
   string filename = GetStatusFilename(/*relative=*/true);
   if (!StringLen(filename)) return(false);

   filename = StrLeftTo(filename, ".", -1) +" "+ GmtTimeFormat(TimeServer(), "%Y.%m.%d %H.%M.%S") + ifString(StringLen(comment), " "+ comment, "") +".gif";

   int width      = 1600;
   int height     =  900;
   int startbar   =  360;        // left-side bar index for an image width of 1600 pixel and margin-right of ~70 pixel with scale=2
   int chartScale =    2;
   int barMode    =   -1;        // the current bar mode

   if (WindowScreenShot(filename, width, height, startbar, chartScale, barMode))
      return(true);
   return(!logError("MakeScreenshot(1)", intOr(GetLastError(), ERR_RUNTIME_ERROR)));    // don't terminate the program
}


/**
 * Return a string representation of the input parameters (for logging purposes).
 *
 * @return string
 */
string InputsToStr() {
   return(StringConcatenate("Sequence.ID=",            DoubleQuoteStr(Sequence.ID),                  ";", NL,
                            "GridDirection=",          DoubleQuoteStr(GridDirection),                ";", NL,
                            "GridVolatility=",         DoubleQuoteStr(GridVolatility),               ";", NL,
                            "GridSize=",               DoubleQuoteStr(GridSize),                     ";", NL,
                            "UnitSize=",               NumberToStr(UnitSize, ".1+"),                 ";", NL,
                            "MaxUnits=",               MaxUnits,                                     ";", NL,
                            "Pyramid.Multiplier=",     NumberToStr(Pyramid.Multiplier, ".1+"),       ";", NL,
                            "Martingale.Multiplier=",  NumberToStr(Martingale.Multiplier, ".1+"),    ";", NL,
                            "StopConditions=",         DoubleQuoteStr(StopConditions),               ";", NL,
                            "ShowProfitInPercent=",    BoolToStr(ShowProfitInPercent),               ";", NL,
                            "Sessionbreak.StartTime=", TimeToStr(Sessionbreak.StartTime, TIME_FULL), ";", NL,
                            "Sessionbreak.EndTime=",   TimeToStr(Sessionbreak.EndTime, TIME_FULL),   ";")
   );
}
