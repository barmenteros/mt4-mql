/**
 * XMT-Scalper revisited
 *
 *
 * This EA is originally based on the famous "MillionDollarPips EA". The core idea of the strategy is scalping based on a
 * reversal from a channel breakout. Over the years it has gone through multiple transformations. Today various versions with
 * different names circulate in the internet (MDP-Plus, XMT-Scalper, Assar). None of them is suitable for real trading, mainly
 * due to lack of signal documentation and a significant amount of issues in the program logic.
 *
 * This version is a complete rewrite.
 *
 * Sources:
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/a1b22d0/mql4/experts/mdp#             [MillionDollarPips v2 decompiled]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/36f494e/mql4/experts/mdp#                    [MDP-Plus v2.2 by Capella]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/23c51cc/mql4/experts/mdp#                   [MDP-Plus v2.23 by Capella]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/a0c2411/mql4/experts/mdp#                [XMT-Scalper v2.41 by Capella]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/8f5f29e/mql4/experts/mdp#                [XMT-Scalper v2.42 by Capella]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/513f52c/mql4/experts/mdp#                [XMT-Scalper v2.46 by Capella]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/b3be98e/mql4/experts/mdp#               [XMT-Scalper v2.461 by Capella]
 *  @link  https://github.com/rosasurfer/mt4-mql/blob/41237e0/mql4/experts/mdp#               [XMT-Scalper v2.522 by Capella]
 *
 * Changes:
 *  - removed MQL5 syntax
 *  - integrated the rosasurfer MQL4 framework
 *  - moved all print output to the framework logger
 *  - removed flawed commission calculations
 *  - removed obsolete order expiration, NDD and screenshot functionality
 *  - removed obsolete sending of fake orders and measuring of execution times
 *  - removed obsolete functions and variables
 *  - reorganized input parameters
 *  - fixed signal detection (added input parameter ChannelBug for comparison)
 *  - fixed TakeProfit calculation (added input parameter TakeProfitBug for comparison)
 *  - replaced position size calculation
 *  - replaced magic number calculation
 *  - replaced trade management
 *  - replaced status display
 *  - added monitoring of PositionOpen and PositionClose events
 *  - added virtual trading mode with optional trade-copier or trade-mirror
 */
#include <stddefines.mqh>
int   __InitFlags[] = {INIT_TIMEZONE, INIT_PIPVALUE, INIT_BUFFERED_LOG};
int __DeinitFlags[];

////////////////////////////////////////////////////// Configuration ////////////////////////////////////////////////////////

extern string Sequence.ID                     = "";         // instance id in the range of 1000-16383
extern string TradingMode                     = "Regular* | Virtual | Virtual-Copier | Virtual-Mirror";     // also "R | V | VC | VM"

extern string ___a___________________________ = "=== Entry indicator: 1=MovingAverage, 2=BollingerBands, 3=Envelopes ===";
extern int    EntryIndicator                  = 1;          // entry signal indicator for price channel calculation
extern int    IndicatorTimeframe              = PERIOD_M1;  // entry indicator timeframe
extern int    IndicatorPeriods                = 3;          // entry indicator bar periods
extern double BollingerBands.Deviation        = 2;          // standard deviations
extern double Envelopes.Deviation             = 0.07;       // in percent

extern string ___b___________________________ = "=== Entry bar size conditions ================";
extern bool   UseSpreadMultiplier             = true;       // use spread multiplier or fixed min. bar size
extern double SpreadMultiplier                = 12.5;       // min. bar size = SpreadMultiplier * avgSpread
extern double MinBarSize                      = 18;         // min. bar size in {pip}

extern string ___c___________________________ = "=== Signal settings ========================";
extern double BreakoutReversal                = 0;          // required price reversal in {pip} (0: counter-trend trading w/o reversal)
extern double MaxSpread                       = 2;          // max. acceptable current and average spread in {pip}
extern bool   ReverseSignals                  = false;      // Buy => Sell, Sell => Buy

extern string ___d___________________________ = "=== MoneyManagement ====================";
extern bool   MoneyManagement                 = true;       // TRUE: calculate lots dynamically; FALSE: use "ManualLotsize"
extern double Risk                            = 2;          // percent of equity to risk with each trade
extern double ManualLotsize                   = 0.01;       // fix position to use if "MoneyManagement" is FALSE

extern string ___e___________________________ = "=== Trade settings ========================";
extern double TakeProfit                      = 10;         // TP in {pip}
extern double StopLoss                        = 6;          // SL in {pip}
extern double TrailEntryStep                  = 1;          // trail entry limits every {pip}
extern double TrailExitStart                  = 0;          // start trailing exit limits after {pip} in profit
extern double TrailExitStep                   = 2;          // trail exit limits every {pip} in profit
extern int    MagicNumber                     = 0;          // predefined magic order id, if zero a new one is generated
extern double MaxSlippage                     = 0.3;        // max. acceptable slippage in {pip}

extern string ___f___________________________ = "=== Overall PL settings =====================";
extern double EA.StopOnProfit                 = 0;          // stop on overall profit in {money} (0: no stop on profits)
extern double EA.StopOnLoss                   = 0;          // stop on overall loss in {money} (0: no stop on losses)

extern string ___g___________________________ = "=== Bugs ================================";
extern bool   ChannelBug                      = false;      // enable erroneous calculation of the breakout channel (for comparison only)
extern bool   TakeProfitBug                   = true;       // enable erroneous calculation of TakeProfit targets (for comparison only)

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include <core/expert.mqh>
#include <stdfunctions.mqh>
#include <rsfLibs.mqh>
#include <functions/JoinStrings.mqh>
#include <structs/rsf/OrderExecution.mqh>

#define STRATEGY_ID               106           // unique strategy id from 101-1023 (10 bits)

#define TRADINGMODE_REGULAR         1
#define TRADINGMODE_VIRTUAL         2
#define TRADINGMODE_VIRTUAL_COPIER  3
#define TRADINGMODE_VIRTUAL_MIRROR  4

#define SIGNAL_LONG                 1
#define SIGNAL_SHORT                2


// general
int      tradingMode;
int      sequence.id;

// real order log
int      real.ticket      [];
int      real.linkedTicket[];                   // linked virtual ticket (if any)
double   real.lots        [];                   // order volume > 0
int      real.pendingType [];                   // pending order type if applicable or OP_UNDEFINED (-1)
double   real.pendingPrice[];                   // pending entry limit if applicable or 0
int      real.openType    [];                   // order open type of an opened position or OP_UNDEFINED (-1)
datetime real.openTime    [];                   // order open time of an opened position or 0
double   real.openPrice   [];                   // order open price of an opened position or 0
datetime real.closeTime   [];                   // order close time of a closed order or 0
double   real.closePrice  [];                   // order close price of a closed position or 0
double   real.stopLoss    [];                   // SL price or 0
double   real.takeProfit  [];                   // TP price or 0
double   real.commission  [];                   // order commission
double   real.swap        [];                   // order swap
double   real.profit      [];                   // order profit (gross)

// real order statistics
bool     real.isSynchronized;                   // whether real and virtual trading are synchronized
bool     real.isOpenOrder;                      // whether an open order exists (max. 1 open order)
bool     real.isOpenPosition;                   // whether an open position exists (max. 1 open position)

double   real.openLots;                         // total open lotsize: -n...+n
double   real.openSwap;                         // total open swap
double   real.openCommission;                   // total open commissions
double   real.openPl;                           // total open gross profit
double   real.openPlNet;                        // total open net profit

int      real.closedPositions;                  // number of closed positions
double   real.closedLots;                       // total closed lotsize: 0...+n
double   real.closedCommission;                 // total closed commission
double   real.closedSwap;                       // total closed swap
double   real.closedPl;                         // total closed gross profit
double   real.closedPlNet;                      // total closed net profit

double   real.totalPlNet;                       // openPlNet + closedPlNet

// virtual order log
int      virt.ticket      [];
int      virt.linkedTicket[];                   // linked real ticket (if any)
double   virt.lots        [];
int      virt.pendingType [];
double   virt.pendingPrice[];
int      virt.openType    [];
datetime virt.openTime    [];
double   virt.openPrice   [];
datetime virt.closeTime   [];
double   virt.closePrice  [];
double   virt.stopLoss    [];
double   virt.takeProfit  [];
double   virt.commission  [];
double   virt.swap        [];
double   virt.profit      [];

// virtual order statistics
bool     virt.isOpenOrder;
bool     virt.isOpenPosition;

double   virt.openLots;
double   virt.openCommission;
double   virt.openSwap;
double   virt.openPl;
double   virt.openPlNet;

int      virt.closedPositions;
double   virt.closedLots;
double   virt.closedCommission;
double   virt.closedSwap;
double   virt.closedPl;
double   virt.closedPlNet;

double   virt.totalPlNet;

// other
double   currentSpread;                         // current spread in pip
double   avgSpread;                             // average spread in pip
double   minBarSize;                            // min. bar size in absolute terms
int      orderSlippage;                         // order slippage in point
int      orderMagicNumber;
string   orderComment = "";

// cache vars to speed-up status messages
string   sTradingModeDescriptions[] = {"", "", ": Virtual Trading", ": Virtual Trading + Trade Copier", ": Virtual Trading + Trade Mirror"};
string   sCurrentSpread             = "-";
string   sAvgSpread                 = "-";
string   sMaxSpread                 = "-";
string   sCurrentBarSize            = "-";
string   sMinBarSize                = "-";
string   sIndicator                 = "-";
string   sUnitSize                  = "-";

// debug settings                               // configurable via framework config, @see XMT-Scalper::afterInit()
bool     tester.onPositionOpenPause = false;    // whether to pause the tester on PositionOpen events


#include <apps/xmt-scalper/init.mqh>
#include <apps/xmt-scalper/deinit.mqh>


/**
 * Main function
 *
 * @return int - error status
 */
int onTick() {
   double dNull;
   if (ChannelBug) GetIndicatorValues(dNull, dNull, dNull);       // if the channel bug is enabled indicators must be tracked every tick
   if (__isChart)  CalculateSpreads();                            // for the visible spread status display

   if (tradingMode == TRADINGMODE_REGULAR)
      return(onTick.RegularTrading());
   return(onTick.VirtualTrading());
}


/**
 * Main function for regular trading.
 *
 * @return int - error status
 */
int onTick.RegularTrading() {
   UpdateRealOrderStatus();                                       // update real order status and PL

   if (EA.StopOnProfit || EA.StopOnLoss) {
      if (!CheckTotalTargets()) return(last_error);               // i.e. ERR_CANCELLED_BY_USER
   }

   if (real.isOpenOrder) {
      if (real.isOpenPosition) ManageOpenPosition();              // trail exit limits
      else                     ManagePendingOrder();              // trail entry limits or delete order
   }

   if (!last_error && !real.isOpenOrder) {
      int signal;
      if (IsEntrySignal(signal)) OpenNewOrder(signal);            // monitor and handle new entry signals
   }
   return(last_error);
}


/**
 * Main function for virtual trading.
 *
 * @return int - error status
 */
int onTick.VirtualTrading() {
   if (__isChart) HandleCommands();                               // process chart commands

   UpdateVirtualOrderStatus();                                    // update virtual order status and PL

   if (virt.isOpenOrder) {
      if (virt.isOpenPosition) ManageVirtualPosition();           // trail exit limits
      else                     ManageVirtualOrder();              // trail entry limits or delete order
   }

   if (!last_error && !virt.isOpenOrder) {
      int signal;
      if (IsEntrySignal(signal)) OpenVirtualOrder(signal);        // monitor and handle new entry signals
   }

   if (tradingMode == TRADINGMODE_VIRTUAL_COPIER) return(onTick.TradeCopier());
   if (tradingMode == TRADINGMODE_VIRTUAL_MIRROR) return(onTick.TradeMirror());
   return(last_error);
}


/**
 * Main function for the trade copier.
 *
 * @return int - error status
 */
int onTick.TradeCopier() {
   if (!real.isSynchronized) {
      if (!SynchronizeTradeCopier()) return(last_error);
   }

   // manage new trades
   // - listen to virtual PositionOpen/PositionClose events
   // - listen to signals

   return(last_error);
}


/**
 * Main function for the trade mirror.
 *
 * @return int - error status
 */
int onTick.TradeMirror() {
   if (!real.isSynchronized) {
      if (!SynchronizeTradeMirror()) return(last_error);
   }
   return(catch("onTick.TradeMirror(1)", ERR_NOT_IMPLEMENTED));
}


/**
 * Synchronize the trade copier with virtual trading.
 *
 * @return bool - success status
 */
bool SynchronizeTradeCopier() {
   if (real.isSynchronized) return(true);

   if (!virt.isOpenOrder) {
      if (real.isOpenOrder) return(!catch("SynchronizeTradeCopier(1)  virt.isOpenOrder=FALSE  real.isOpenOrder=TRUE", ERR_ILLEGAL_STATE));
      real.isSynchronized = true;
      return(true);
   }

   int iV = ArraySize(virt.ticket)-1, oe[];
   int iR = ArraySize(real.ticket)-1;

   if (virt.isOpenPosition) {
      if (real.isOpenPosition) {
         // an open position exists, check directions
         if (virt.openType[iV] != real.openType[iR])                            return(!catch("SynchronizeTradeCopier(2)  trade direction mis-match: virt.openType="+ OperationTypeDescription(virt.openType[iV]) +", real.openType="+ OperationTypeDescription(real.openType[iR]), ERR_ILLEGAL_STATE));
         // check tickets
         if (virt.linkedTicket[iV] && virt.linkedTicket[iV] != real.ticket[iR]) return(!catch("SynchronizeTradeCopier(3)  ticket mis-match: virt.linkedTicket="+ virt.linkedTicket[iV] +", real.ticket="+ real.ticket[iR], ERR_ILLEGAL_STATE));
         if (real.linkedTicket[iR] && real.linkedTicket[iR] != virt.ticket[iV]) return(!catch("SynchronizeTradeCopier(4)  ticket mis-match: real.linkedTicket="+ real.linkedTicket[iR] +", virt.ticket="+ virt.ticket[iV], ERR_ILLEGAL_STATE));
         // update the link
         virt.linkedTicket[iV] = real.ticket[iR];
         real.linkedTicket[iR] = virt.ticket[iV];
      }
      else if (real.isOpenOrder) return(!catch("SynchronizeTradeCopier(5)  virt.isOpenPosition=TRUE  real.isPendingOrder=TRUE", ERR_NOT_IMPLEMENTED));
      else {
         // an open position doesn't exist, open it
         double lots = CalculateLots(true); if (!lots) return(false);
         color markerColor = ifInt(virt.openType[iV]==OP_LONG, Blue, Red);
                                                                                // TP and SL are updated by the regular onTick() function
         OrderSendEx(Symbol(), virt.openType[iV], lots, NULL, orderSlippage, NULL, NULL, orderComment, orderMagicNumber, NULL, markerColor, NULL, oe);
         if (oe.IsError(oe)) return(false);

         // update the link
         Orders.AddRealTicket(oe.Ticket(oe), virt.ticket[iV], oe.Lots(oe), oe.Type(oe), oe.OpenTime(oe), oe.OpenPrice(oe), NULL, NULL, oe.StopLoss(oe), oe.TakeProfit(oe), NULL, NULL, NULL);
         virt.linkedTicket[iV] = oe.Ticket(oe);
      }
   }
   else return(!catch("SynchronizeTradeCopier(6)  virt.isPendingOrder=TRUE, synchronization not implemented", ERR_NOT_IMPLEMENTED));

   real.isSynchronized = true;
   return(true);
}


/**
 * Synchronize the trade mirror with virtual trading.
 *
 * @return bool - success status
 */
bool SynchronizeTradeMirror() {
   if (real.isSynchronized) return(true);

   return(!catch("SynchronizeTradeMirror(1)", ERR_NOT_IMPLEMENTED));
}


/**
 * Update real order status and PL statistics.
 *
 * @return bool - success status
 */
bool UpdateRealOrderStatus() {
   // open order statistics are fully recalculated
   real.isOpenOrder    = false;
   real.isOpenPosition = false;
   real.openLots       = 0;
   real.openCommission = 0;
   real.openSwap       = 0;
   real.openPl         = 0;
   real.openPlNet      = 0;

   int orders = ArraySize(real.ticket);

   // update ticket status
   for (int i=orders-1; i >= 0; i--) {                            // iterate backwards and stop at the first closed ticket
      if (real.closeTime[i] > 0) break;                           // to increase performance
      real.isOpenOrder = true;
      if (!SelectTicket(real.ticket[i], "UpdateRealOrderStatus(1)")) return(false);

      bool wasPending  = (real.openType[i] == OP_UNDEFINED);
      bool isPending   = (OrderType() > OP_SELL);
      bool wasPosition = !wasPending;
      bool isOpen      = !OrderCloseTime();
      bool isClosed    = !isOpen;

      if (wasPending) {
         if (!isPending) {                                        // the pending order was filled
            onPositionOpen(i);                                    // updates order record and logs
            wasPosition = true;                                   // mark as a known open position
         }
         else if (isClosed) {                                     // the pending order was cancelled (externally)
            onOrderDelete(i);                                     // logs and removes order record
            orders--;
            continue;
         }
      }

      if (wasPosition) {
         real.commission[i] = OrderCommission();
         real.swap      [i] = OrderSwap();
         real.profit    [i] = OrderProfit();

         if (isOpen) {
            real.isOpenPosition  = true;
            real.openLots       += ifDouble(real.openType[i]==OP_BUY, real.lots[i], -real.lots[i]);
            real.openCommission += real.commission[i];
            real.openSwap       += real.swap      [i];
            real.openPl         += real.profit    [i];
         }
         else /*isClosed*/ {                                      // the position was closed
            onPositionClose(i);                                   // updates order record and logs
            real.isOpenOrder = false;
            real.closedPositions++;                               // update closed trade statistics
            real.closedLots       += real.lots      [i];
            real.closedCommission += real.commission[i];
            real.closedSwap       += real.swap      [i];
            real.closedPl         += real.profit    [i];
         }
      }
   }

   real.openPlNet   = real.openSwap   + real.openCommission   + real.openPl;
   real.closedPlNet = real.closedSwap + real.closedCommission + real.closedPl;
   real.totalPlNet  = real.openPlNet  + real.closedPlNet;

   return(!catch("UpdateRealOrderStatus(2)"));
}


/**
 * Update virtual order status PL statistics.
 *
 * @return bool - success status
 */
bool UpdateVirtualOrderStatus() {
   // open order statistics are fully recalculated
   virt.isOpenOrder    = false;
   virt.isOpenPosition = false;
   virt.openLots       = 0;
   virt.openCommission = 0;
   virt.openSwap       = 0;
   virt.openPl         = 0;
   virt.openPlNet      = 0;

   int orders = ArraySize(virt.ticket);

   for (int i=orders-1; i >= 0; i--) {                            // iterate backwards and stop at the first closed ticket
      if (virt.closeTime[i] > 0) break;                           // to increase performance
      virt.isOpenOrder = true;

      bool wasPending = (virt.openType[i] == OP_UNDEFINED);
      bool isPending  = wasPending;
      if (wasPending) {
         if      (virt.pendingType[i] == OP_BUYLIMIT)  { if (LE(Ask, virt.pendingPrice[i])) isPending = false; }
         else if (virt.pendingType[i] == OP_BUYSTOP)   { if (GE(Ask, virt.pendingPrice[i])) isPending = false; }
         else if (virt.pendingType[i] == OP_SELLLIMIT) { if (GE(Bid, virt.pendingPrice[i])) isPending = false; }
         else if (virt.pendingType[i] == OP_SELLSTOP)  { if (LE(Bid, virt.pendingPrice[i])) isPending = false; }
      }
      bool wasPosition = !wasPending;

      if (wasPending) {
         if (!isPending) {                                        // the entry limit was triggered
            onVirtualPositionOpen(i);
            wasPosition = true;                                   // mark as a known open position (may be opened and closed on the same tick)
         }
      }

      if (wasPosition) {
         bool isOpen = true;
         if (virt.openType[i] == OP_BUY) {
            if (virt.takeProfit[i] && GE(Bid, virt.takeProfit[i])) { virt.closePrice[i] = virt.takeProfit[i]; isOpen = false; }
            if (virt.stopLoss  [i] && LE(Bid, virt.stopLoss  [i])) { virt.closePrice[i] = virt.stopLoss  [i]; isOpen = false; }
         }
         else /*virt.openType[i] == OP_SELL*/ {
            if (virt.takeProfit[i] && LE(Ask, virt.takeProfit[i])) { virt.closePrice[i] = virt.takeProfit[i]; isOpen = false; }
            if (virt.stopLoss  [i] && GE(Ask, virt.stopLoss  [i])) { virt.closePrice[i] = virt.stopLoss  [i]; isOpen = false; }
         }

         if (isOpen) {
            virt.isOpenPosition  = true;
            virt.profit[i]       = ifDouble(virt.openType[i]==OP_BUY, Bid-virt.openPrice[i], virt.openPrice[i]-Ask)/Pip * PipValue(virt.lots[i]);
            virt.openLots       += ifDouble(virt.openType[i]==OP_BUY, virt.lots[i], -virt.lots[i]);
            virt.openCommission += virt.commission[i];            // swap is ignored in virtual trading
            virt.openPl         += virt.profit    [i];
         }
         else /*isClosed*/ {                                      // an exit limit was triggered
            virt.isOpenOrder = false;                             // mark order status
            onVirtualPositionClose(i);                            // updates order record, exit PL and logs
            virt.closedPositions++;                               // update closed trade statistics
            virt.closedLots       += virt.lots      [i];
            virt.closedCommission += virt.commission[i];
            virt.closedPl         += virt.profit    [i];
         }
      }
   }

   virt.openPlNet   = virt.openSwap   + virt.openCommission   + virt.openPl;
   virt.closedPlNet = virt.closedSwap + virt.closedCommission + virt.closedPl;
   virt.totalPlNet  = virt.openPlNet  + virt.closedPlNet;

   return(!catch("UpdateVirtualOrderStatus(2)"));
}


/**
 * Handle a real PositionOpen event. The referenced ticket is selected.
 *
 * @param  int i - ticket index of the opened position
 *
 * @return bool - success status
 */
bool onPositionOpen(int i) {
   // update order log
   real.openType  [i] = OrderType();
   real.openTime  [i] = OrderOpenTime();
   real.openPrice [i] = OrderOpenPrice();
   real.commission[i] = OrderCommission();
   real.swap      [i] = OrderSwap();
   real.profit    [i] = OrderProfit();

   if (IsLogDebug()) {
      // #1 Stop Sell 0.1 GBPUSD at 1.5457'2[ "comment"] was filled[ at 1.5457'2] (market: Bid/Ask[, 0.3 pip [positive ]slippage])
      int    pendingType  = real.pendingType [i];
      double pendingPrice = real.pendingPrice[i];

      string sType         = OperationTypeDescription(pendingType);
      string sPendingPrice = NumberToStr(pendingPrice, PriceFormat);
      string sComment      = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message       = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() +" at "+ sPendingPrice + sComment +" was filled";

      string sSlippage = "";
      if (NE(OrderOpenPrice(), pendingPrice, Digits)) {
         double slippage = NormalizeDouble((pendingPrice-OrderOpenPrice())/Pip, 1); if (OrderType() == OP_SELL) slippage = -slippage;
            if (slippage > 0) sSlippage = ", "+ DoubleToStr(slippage, Digits & 1) +" pip positive slippage";
            else              sSlippage = ", "+ DoubleToStr(-slippage, Digits & 1) +" pip slippage";
         message = message +" at "+ NumberToStr(OrderOpenPrice(), PriceFormat);
      }
      logDebug("onPositionOpen(1)  "+ message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) + sSlippage +")");
   }

   if (IsTesting()) {
      if (__ExecutionContext[EC.extReporting] != 0) {
         Test_onPositionOpen(__ExecutionContext, OrderTicket(), OrderType(), OrderLots(), OrderSymbol(), OrderOpenTime(), OrderOpenPrice(), OrderStopLoss(), OrderTakeProfit(), OrderCommission(), OrderMagicNumber(), OrderComment());
      }
      // pause the tester according to the debug configuration
      if (IsVisualMode() && tester.onPositionOpenPause) Tester.Pause("onPositionOpen(2)");
   }
   return(!catch("onPositionOpen(3)"));
}


/**
 * Handle a virtual PositionOpen event.
 *
 * @param  int i - ticket index of the opened position
 *
 * @return bool - success status
 */
bool onVirtualPositionOpen(int i) {
   return(!catch("onVirtualPositionOpen(1)", ERR_NOT_IMPLEMENTED));
}


/**
 * Handle a PositionClose event. The referenced ticket is selected.
 *
 * @param  int i - ticket index of the closed position
 *
 * @return bool - success status
 */
bool onPositionClose(int i) {
   // update order log
   real.closeTime [i] = OrderCloseTime();
   real.closePrice[i] = OrderClosePrice();
   real.commission[i] = OrderCommission();
   real.swap      [i] = OrderSwap();
   real.profit    [i] = OrderProfit();

   if (IsLogDebug()) {
      // #1 Sell 0.1 GBPUSD "comment" at 1.5457'2 was closed at 1.5457'2 (market: Bid/Ask)
      string sType       = OperationTypeDescription(OrderType());
      string sOpenPrice  = NumberToStr(OrderOpenPrice(), PriceFormat);
      string sClosePrice = NumberToStr(OrderClosePrice(), PriceFormat);
      string sComment    = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message     = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() + sComment +" at "+ sOpenPrice +" was closed at "+ sClosePrice;
      logDebug("onPositionClose(1)  "+ message +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
   }

   if (IsTesting() && __ExecutionContext[EC.extReporting]) {
      Test_onPositionClose(__ExecutionContext, OrderTicket(), OrderCloseTime(), OrderClosePrice(), OrderSwap(), OrderProfit());
   }
   return(!catch("onPositionClose(2)"));
}


/**
 * Handle a virtual PositionClose event.
 *
 * @param  int i - ticket index of the closed position
 *
 * @return bool - success status
 */
bool onVirtualPositionClose(int i) {
   // update order log
   virt.closeTime[i] = Tick.Time;
   virt.profit   [i] = ifDouble(virt.openType[i]==OP_BUY, virt.closePrice[i]-virt.openPrice[i], virt.openPrice[i]-virt.closePrice[i])/Pip * PipValue(virt.lots[i]);

   if (IsLogDebug()) {
      // virtual #1 Sell 0.1 GBPUSD "comment" at 1.5457'2 was closed at 1.5457'2 [tp|sl] (market: Bid/Ask)
      string sType       = OperationTypeDescription(virt.openType[i]);
      string sOpenPrice  = NumberToStr(virt.openPrice[i], PriceFormat);
      string sClosePrice = NumberToStr(virt.closePrice[i], PriceFormat);
      string sCloseType  = "";
         if      (EQ(virt.closePrice[i], virt.takeProfit[i])) sCloseType = " [tp]";
         else if (EQ(virt.closePrice[i], virt.stopLoss  [i])) sCloseType = " [sl]";
      logDebug("onVirtualPositionClose(1)  virtual #"+ virt.ticket[i] +" "+ sType +" "+ NumberToStr(virt.lots[i], ".+") +" "+ Symbol() +" \""+ orderComment +"\" at "+ sOpenPrice +" was closed at "+ sClosePrice + sCloseType +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");
   }
   return(!catch("onVirtualPositionClose(2)"));
}


/**
 * Handle an OrderDelete event. The referenced ticket is selected.
 *
 * @param  int i - ticket index of the deleted order
 *
 * @return bool - success status
 */
bool onOrderDelete(int i) {
   if (IsLogDebug()) {
      // #1 Stop Sell 0.1 GBPUSD at 1.5457'2[ "comment"] was deleted
      int    pendingType  = real.pendingType [i];
      double pendingPrice = real.pendingPrice[i];

      string sType         = OperationTypeDescription(pendingType);
      string sPendingPrice = NumberToStr(pendingPrice, PriceFormat);
      string sComment      = ""; if (StringLen(OrderComment()) > 0) sComment = " "+ DoubleQuoteStr(OrderComment());
      string message       = "#"+ OrderTicket() +" "+ sType +" "+ NumberToStr(OrderLots(), ".+") +" "+ Symbol() +" at "+ sPendingPrice + sComment +" was deleted";
      logDebug("onOrderDelete(3)  "+ message);
   }
   return(Orders.RemoveTicket(real.ticket[i]));
}


/**
 * Whether the conditions of an entry signal are satisfied.
 *
 * @param  _Out_ int signal - identifier of the detected signal or NULL
 *
 * @return bool
 */
bool IsEntrySignal(int &signal) {
   signal = NULL;
   if (last_error || real.isOpenOrder) return(false);

   double high = iHigh(NULL, IndicatorTimeframe, 0);
   double low  =  iLow(NULL, IndicatorTimeframe, 0);
   if (!high) {
      int error = GetLastError();
      if (IsError(error)) {
         if (error == ERS_HISTORY_UPDATE) SetLastError(error);
         else                             catch("IsEntrySignal(1)", error);
         return(false);
      }
   }
   double barSize = high - low;
   if (__isChart) sCurrentBarSize = DoubleToStr(barSize/Pip, 1);

   if (UseSpreadMultiplier) {
      if (!avgSpread) /*&&*/ if (!CalculateSpreads())         return(false);
      if (currentSpread > MaxSpread || avgSpread > MaxSpread) return(false);
      minBarSize = avgSpread*Pip * SpreadMultiplier; if (__isChart) SS.MinBarSize();
   }

   //if (GE(barSize, minBarSize)) {                            // TODO: move double comparators to DLL, 4'310'258 ticks processed in 0:00:07.675
   if (barSize+0.00000001 >= minBarSize) {                     //                                       4'310'258 ticks processed in 0:00:06.755
      double channelHigh, channelLow, dNull;
      if (!GetIndicatorValues(channelHigh, channelLow, dNull)) return(false);

      if      (Bid < channelLow)    signal  = SIGNAL_LONG;
      else if (Bid > channelHigh)   signal  = SIGNAL_SHORT;
      if (signal && ReverseSignals) signal ^= 3;               // flip long and short bits: dec(3) = bin(0011)

      if (signal != NULL) {
         if (IsLogDebug()) logDebug("IsEntrySignal(2)  "+ ifString(signal==SIGNAL_LONG, "LONG", "SHORT") +" signal (barSize="+ DoubleToStr(barSize/Pip, 1) +", minBarSize="+ sMinBarSize +", channel="+ NumberToStr(channelHigh, PriceFormat) +"/"+ NumberToStr(channelLow, PriceFormat) +", Bid="+ NumberToStr(Bid, PriceFormat) +")");
         return(true);
      }
   }
   return(false);
}


/**
 * Open a real order for the specified entry signal.
 *
 * @param  int signal - order entry signal: SIGNAL_LONG|SIGNAL_SHORT
 *
 * @return bool - success status
 */
bool OpenNewOrder(int signal) {
   if (last_error != 0) return(false);

   double lots   = CalculateLots(true); if (!lots) return(false);
   double spread = Ask-Bid, price, takeProfit, stopLoss;
   int oe[];

   if (signal == SIGNAL_LONG) {
      price      = Ask + BreakoutReversal*Pip;
      takeProfit = price + TakeProfit*Pip;
      stopLoss   = price - spread - StopLoss*Pip;

      if (!BreakoutReversal) OrderSendEx(Symbol(), OP_BUY,     lots, NULL,  orderSlippage, stopLoss, takeProfit, orderComment, orderMagicNumber, NULL, Blue, NULL, oe);
      else                   OrderSendEx(Symbol(), OP_BUYSTOP, lots, price, NULL,          stopLoss, takeProfit, orderComment, orderMagicNumber, NULL, Blue, NULL, oe);
   }
   else if (signal == SIGNAL_SHORT) {
      price      = Bid - BreakoutReversal*Pip;
      takeProfit = price - TakeProfit*Pip;
      stopLoss   = price + spread + StopLoss*Pip;

      if (!BreakoutReversal) OrderSendEx(Symbol(), OP_SELL,     lots, NULL,  orderSlippage, stopLoss, takeProfit, orderComment, orderMagicNumber, NULL, Red, NULL, oe);
      else                   OrderSendEx(Symbol(), OP_SELLSTOP, lots, price, NULL,          stopLoss, takeProfit, orderComment, orderMagicNumber, NULL, Red, NULL, oe);
   }
   else return(!catch("OpenNewOrder(1)  invalid parameter signal: "+ signal, ERR_INVALID_PARAMETER));

   if (oe.IsError(oe)) return(false);

   if (IsTesting()) {                           // pause the tester according to the debug configuration
      if (IsVisualMode() && tester.onPositionOpenPause) Tester.Pause("OpenNewOrder(2)");
   }
   return(Orders.AddRealTicket(oe.Ticket(oe), NULL, oe.Lots(oe), oe.Type(oe), oe.OpenTime(oe), oe.OpenPrice(oe), NULL, NULL, oe.StopLoss(oe), oe.TakeProfit(oe), NULL, NULL, NULL));
}


/**
 * Open a virtual order for the specified entry signal.
 *
 * @param  int signal - order entry signal: SIGNAL_LONG|SIGNAL_SHORT
 *
 * @return bool - success status
 */
bool OpenVirtualOrder(int signal) {
   if (last_error != 0) return(false);

   int ticket, orderType;
   double openPrice, stopLoss, takeProfit, spread=Ask-Bid;

   if (signal == SIGNAL_LONG) {
      orderType  = ifInt(BreakoutReversal, OP_BUYSTOP, OP_BUY);
      openPrice  = Ask + BreakoutReversal*Pip;
      takeProfit = openPrice + TakeProfit*Pip;
      stopLoss   = openPrice - spread - StopLoss*Pip;
   }
   else if (signal == SIGNAL_SHORT) {
      orderType  = ifInt(BreakoutReversal, OP_SELLSTOP, OP_SELL);
      openPrice  = Bid - BreakoutReversal*Pip;
      takeProfit = openPrice - TakeProfit*Pip;
      stopLoss   = openPrice + spread + StopLoss*Pip;
   }
   else return(!catch("OpenVirtualOrder(1)  invalid parameter signal: "+ signal, ERR_INVALID_PARAMETER));

   double lots       = CalculateLots();      if (!lots)               return(false);
   double commission = GetCommission(-lots); if (IsEmpty(commission)) return(false);
   if (!Orders.AddVirtualTicket(ticket, NULL, lots, orderType, Tick.Time, openPrice, NULL, NULL, stopLoss, takeProfit, NULL, commission, NULL)) return(false);

   // opened virt. #1 Buy 0.5 GBPUSD "XMT" at 1.5524'8, sl=1.5500'0, tp=1.5600'0 (market: Bid/Ask)
   if (IsLogDebug()) logDebug("OpenVirtualOrder(2)  "+ "opened virtual #"+ ticket +" "+ OperationTypeDescription(orderType) +" "+ NumberToStr(lots, ".+") +" "+ Symbol() +" \""+ orderComment +"\" at "+ NumberToStr(openPrice, PriceFormat) +", sl="+ NumberToStr(stopLoss, PriceFormat) +", tp="+ NumberToStr(takeProfit, PriceFormat) +" (market: "+ NumberToStr(Bid, PriceFormat) +"/"+ NumberToStr(Ask, PriceFormat) +")");

   if (IsTesting()) {                              // pause the tester according to the debug configuration
      if (IsVisualMode() && tester.onPositionOpenPause) Tester.Pause("OpenNewOrder(2)");
   }
   return(true);
}


/**
 * Manage a real pending order (there can be only one).
 *
 * @return bool - success status
 */
bool ManagePendingOrder() {
   if (!real.isOpenOrder || real.isOpenPosition) return(true);

   int i = ArraySize(real.ticket)-1, oe[];
   if (real.openType[i] != OP_UNDEFINED) return(!catch("ManagePendingOrder(1)  illegal order type "+ OperationTypeToStr(real.openType[i]) +" of expected pending order #"+ real.ticket[i], ERR_ILLEGAL_STATE));

   double openprice, stoploss, takeprofit, spread=Ask-Bid, channelMean, dNull;
   if (!GetIndicatorValues(dNull, dNull, channelMean)) return(false);

   switch (real.pendingType[i]) {
      case OP_BUYSTOP:
         if (GE(Bid, channelMean)) {                                    // delete the order if price reached mid of channel
            if (!OrderDeleteEx(real.ticket[i], CLR_NONE, NULL, oe)) return(false);
            Orders.RemoveTicket(real.ticket[i]);
            return(true);
         }
         openprice = Ask + BreakoutReversal*Pip;                        // trail order entry in breakout direction

         if (GE(real.pendingPrice[i]-openprice, TrailEntryStep*Pip)) {
            stoploss   = openprice - spread - StopLoss*Pip;
            takeprofit = openprice + TakeProfit*Pip;
            if (!OrderModifyEx(real.ticket[i], openprice, stoploss, takeprofit, NULL, Lime, NULL, oe)) return(false);
         }
         break;

      case OP_SELLSTOP:
         if (LE(Bid, channelMean)) {                                    // delete the order if price reached mid of channel
            if (!OrderDeleteEx(real.ticket[i], CLR_NONE, NULL, oe)) return(false);
            Orders.RemoveTicket(real.ticket[i]);
            return(true);
         }
         openprice = Bid - BreakoutReversal*Pip;                        // trail order entry in breakout direction

         if (GE(openprice-real.pendingPrice[i], TrailEntryStep*Pip)) {
            stoploss   = openprice + spread + StopLoss*Pip;
            takeprofit = openprice - TakeProfit*Pip;
            if (!OrderModifyEx(real.ticket[i], openprice, stoploss, takeprofit, NULL, Orange, NULL, oe)) return(false);
         }
         break;

      default:
         return(!catch("ManagePendingOrder(2)  illegal order type "+ OperationTypeToStr(real.pendingType[i]) +" of expected pending order #"+ real.ticket[i], ERR_ILLEGAL_STATE));
   }

   if (stoploss > 0) {
      real.pendingPrice[i] = NormalizeDouble(openprice, Digits);
      real.stopLoss    [i] = NormalizeDouble(stoploss, Digits);
      real.takeProfit  [i] = NormalizeDouble(takeprofit, Digits);
   }
   return(true);
}


/**
 * Manage a virtual pending order (there can be only one).
 *
 * @return bool - success status
 */
bool ManageVirtualOrder() {
   return(!catch("ManageVirtualOrder(1)", ERR_NOT_IMPLEMENTED));
}


/**
 * Manage a real open position (there can be only one).
 *
 * @return bool - success status
 */
bool ManageOpenPosition() {
   if (!real.isOpenPosition) return(true);

   int i = ArraySize(real.ticket)-1, oe[];
   double takeProfit, stopLoss;

   switch (real.openType[i]) {
      case OP_BUY:
         if      (TakeProfitBug)                                 takeProfit = Ask + TakeProfit*Pip;      // erroneous TP calculation
         else if (GE(Bid-real.openPrice[i], TrailExitStart*Pip)) takeProfit = Bid + TakeProfit*Pip;      // correct TP calculation, also check trail-start
         else                                                    takeProfit = INT_MIN;

         if (GE(takeProfit-real.takeProfit[i], TrailExitStep*Pip)) {
            stopLoss = Bid - StopLoss*Pip;
            if (!OrderModifyEx(real.ticket[i], NULL, stopLoss, takeProfit, NULL, Lime, NULL, oe)) return(false);
         }
         break;

      case OP_SELL:
         if      (TakeProfitBug)                                 takeProfit = Bid - TakeProfit*Pip;      // erroneous TP calculation
         else if (GE(real.openPrice[i]-Ask, TrailExitStart*Pip)) takeProfit = Ask - TakeProfit*Pip;      // correct TP calculation, also check trail-start
         else                                                    takeProfit = INT_MAX;

         if (GE(real.takeProfit[i]-takeProfit, TrailExitStep*Pip)) {
            stopLoss = Ask + StopLoss*Pip;
            if (!OrderModifyEx(real.ticket[i], NULL, stopLoss, takeProfit, NULL, Orange, NULL, oe)) return(false);
         }
         break;

      default:
         return(!catch("ManageOpenPosition(1)  illegal order type "+ OperationTypeToStr(real.openType[i]) +" of expected open position #"+ real.ticket[i], ERR_ILLEGAL_STATE));
   }

   if (stopLoss > 0) {
      real.takeProfit[i] = NormalizeDouble(takeProfit, Digits);
      real.stopLoss  [i] = NormalizeDouble(stopLoss, Digits);
   }
   return(true);
}


/**
 * Manage a virtual open position (there can be only one).
 *
 * @return bool - success status
 */
bool ManageVirtualPosition() {
   if (!virt.isOpenPosition) return(true);

   int i = ArraySize(virt.ticket)-1;
   double takeProfit, stopLoss;

   switch (virt.openType[i]) {
      case OP_BUY:
         if      (TakeProfitBug)                                   takeProfit = Ask + TakeProfit*Pip;    // erroneous TP calculation
         else if (GE(Bid-virt.openPrice[i], TrailExitStart*Pip))   takeProfit = Bid + TakeProfit*Pip;    // correct TP calculation, also check trail-start
         else                                                      takeProfit = INT_MIN;
         if (GE(takeProfit-virt.takeProfit[i], TrailExitStep*Pip)) stopLoss   = Bid - StopLoss*Pip;
         break;

      case OP_SELL:
         if      (TakeProfitBug)                                   takeProfit = Bid - TakeProfit*Pip;    // erroneous TP calculation
         else if (GE(virt.openPrice[i]-Ask, TrailExitStart*Pip))   takeProfit = Ask - TakeProfit*Pip;    // correct TP calculation, also check trail-start
         else                                                      takeProfit = INT_MAX;
         if (GE(virt.takeProfit[i]-takeProfit, TrailExitStep*Pip)) stopLoss   = Ask + StopLoss*Pip;
         break;

      default:
         return(!catch("ManageVirtualPosition(1)  illegal order type "+ OperationTypeToStr(virt.openType[i]) +" of expected virtual position #"+ virt.ticket[i], ERR_ILLEGAL_STATE));
   }

   if (stopLoss > 0) {
      virt.takeProfit[i] = NormalizeDouble(takeProfit, Digits);
      virt.stopLoss  [i] = NormalizeDouble(stopLoss, Digits);
   }
   return(true);
}


/**
 * Check total profit targets and stop the EA if targets have been reached.
 *
 * @return bool - whether the EA shall continue trading, i.e. FALSE on EA stop or in case of errors
 */
bool CheckTotalTargets() {
   bool stopEA = false;
   if (EA.StopOnProfit != 0) stopEA = stopEA || GE(real.totalPlNet, EA.StopOnProfit);
   if (EA.StopOnLoss   != 0) stopEA = stopEA || LE(real.totalPlNet, EA.StopOnProfit);

   if (stopEA) {
      if (!CloseOpenOrders())
         return(false);
      return(!SetLastError(ERR_CANCELLED_BY_USER));
   }
   return(true);
}


/**
 * Close all open orders.
 *
 * @return bool - success status
 */
bool CloseOpenOrders() {
   return(!catch("CloseOpenOrders(1)", ERR_NOT_IMPLEMENTED));
}


/**
 * Calculate current and average spread. Online at least 30 ticks are collected before calculating an average.
 *
 * @return bool - success status; FALSE if the average is not yet available
 */
bool CalculateSpreads() {
   static bool lastResult = false;
   static int  lastTick; if (Tick == lastTick) {
      return(lastResult);
   }
   lastTick      = Tick;
   currentSpread = NormalizeDouble((Ask-Bid)/Pip, 1);

   if (IsTesting()) {
      avgSpread  = currentSpread; if (__isChart) SS.Spreads();
      lastResult = true;
      return(lastResult);
   }

   double spreads[30];
   ArrayCopy(spreads, spreads, 0, 1);
   spreads[29] = currentSpread;

   static int ticks = 0;
   if (ticks < 29) {
      ticks++;
      avgSpread  = NULL; if (__isChart) SS.Spreads();
      lastResult = false;
      return(lastResult);
   }

   double sum = 0;
   for (int i=0; i < ticks; i++) {
      sum += spreads[i];
   }
   avgSpread  = sum/ticks; if (__isChart) SS.Spreads();
   lastResult = true;

   return(lastResult);
}


/**
 * Return the indicator values forming the signal channel.
 *
 * @param  _Out_ double channelHigh - current upper channel band
 * @param  _Out_ double channelLow  - current lower channel band
 * @param  _Out_ double channelMean - current mid channel
 *
 * @return bool - success status
 */
bool GetIndicatorValues(double &channelHigh, double &channelLow, double &channelMean) {
   static double lastHigh, lastLow, lastMean;
   static int lastTick; if (Tick == lastTick) {
      channelHigh = lastHigh;                   // return cached values
      channelLow  = lastLow;
      channelMean = lastMean;
      return(true);
   }
   lastTick = Tick;

   if (EntryIndicator == 1) {
      channelHigh = iMA(Symbol(), IndicatorTimeframe, IndicatorPeriods, 0, MODE_LWMA, PRICE_HIGH, 0);
      channelLow  = iMA(Symbol(), IndicatorTimeframe, IndicatorPeriods, 0, MODE_LWMA, PRICE_LOW, 0);
      channelMean = (channelHigh + channelLow)/2;
   }
   else if (EntryIndicator == 2) {
      channelHigh = iBands(Symbol(), IndicatorTimeframe, IndicatorPeriods, BollingerBands.Deviation, 0, PRICE_OPEN, MODE_UPPER, 0);
      channelLow  = iBands(Symbol(), IndicatorTimeframe, IndicatorPeriods, BollingerBands.Deviation, 0, PRICE_OPEN, MODE_LOWER, 0);
      channelMean = (channelHigh + channelLow)/2;
   }
   else if (EntryIndicator == 3) {
      channelHigh = iEnvelopes(Symbol(), IndicatorTimeframe, IndicatorPeriods, MODE_LWMA, 0, PRICE_OPEN, Envelopes.Deviation, MODE_UPPER, 0);
      channelLow  = iEnvelopes(Symbol(), IndicatorTimeframe, IndicatorPeriods, MODE_LWMA, 0, PRICE_OPEN, Envelopes.Deviation, MODE_LOWER, 0);
      channelMean = (channelHigh + channelLow)/2;
   }
   else return(!catch("GetIndicatorValues(1)  illegal variable EntryIndicator: "+ EntryIndicator, ERR_ILLEGAL_STATE));

   if (ChannelBug) {                            // reproduce Capella's channel calculation bug (for comparison only)
      if (lastHigh && Bid < channelMean) {      // if enabled the function is called every tick
         channelHigh = lastHigh;
         channelLow  = lastLow;                 // return expired band values
      }
   }
   if (__isChart) {
      static string names[4] = {"", "MovingAverage", "BollingerBands", "Envelopes"};
      sIndicator = StringConcatenate(names[EntryIndicator], "    ", NumberToStr(channelMean, PriceFormat), "  �", DoubleToStr((channelHigh-channelLow)/Pip/2, 1) ,"  (", NumberToStr(channelHigh, PriceFormat), "/", NumberToStr(channelLow, PriceFormat) ,")", ifString(ChannelBug, "   ChannelBug=1", ""));
   }

   lastHigh = channelHigh;                      // cache returned values
   lastLow  = channelLow;
   lastMean = channelMean;

   int error = GetLastError();
   if (!error)                      return(true);
   if (error == ERS_HISTORY_UPDATE) return(false);
   return(!catch("GetIndicatorValues(2)", error));
}


/**
 * Calculate the position size to use.
 *
 * @param  bool checkLimits [optional] - whether to check the symbol's lotsize contraints (default: no)
 *
 * @return double - position size or NULL in case of errors
 */
double CalculateLots(bool checkLimits = false) {
   checkLimits = checkLimits!=0;
   static double lots, lastLots;

   if (MoneyManagement) {
      double equity = AccountEquity() - AccountCredit();
      if (LE(equity, 0)) return(!catch("CalculateLots(1)  equity: "+ DoubleToStr(equity, 2), ERR_NOT_ENOUGH_MONEY));

      double riskPerTrade = Risk/100 * equity;                          // risked equity amount per trade
      double riskPerPip   = riskPerTrade/StopLoss;                      // risked equity amount per pip

      lots = NormalizeLots(riskPerPip/PipValue(), NULL, MODE_FLOOR);    // resulting normalized position size
      if (IsEmptyValue(lots)) return(NULL);

      if (checkLimits) {
         double minLots = MarketInfo(Symbol(), MODE_MINLOT);
         if (LT(lots, minLots)) return(!catch("CalculateLots(2)  equity: "+ DoubleToStr(equity, 2) +" (resulting position size smaller than MODE_MINLOT of "+ NumberToStr(minLots, ".1+") +")", ERR_NOT_ENOUGH_MONEY));

         double maxLots = MarketInfo(Symbol(), MODE_MAXLOT);
         if (GT(lots, maxLots)) {
            if (LT(lastLots, maxLots)) logNotice("CalculateLots(3)  limiting position size to MODE_MAXLOT: "+ NumberToStr(maxLots, ".+") +" lot");
            lots = maxLots;
         }
      }
   }
   else {
      lots = ManualLotsize;
   }
   lastLots = lots;

   if (__isChart) SS.UnitSize(lots);
   return(lots);
}


/**
 * Read and store the full order history.
 *
 * @return bool - success status
 */
bool ReadOrderLog() {
   ArrayResize(real.ticket,       0);
   ArrayResize(real.linkedTicket, 0);
   ArrayResize(real.lots,         0);
   ArrayResize(real.pendingType,  0);
   ArrayResize(real.pendingPrice, 0);
   ArrayResize(real.openType,     0);
   ArrayResize(real.openTime,     0);
   ArrayResize(real.openPrice,    0);
   ArrayResize(real.closeTime,    0);
   ArrayResize(real.closePrice,   0);
   ArrayResize(real.stopLoss,     0);
   ArrayResize(real.takeProfit,   0);
   ArrayResize(real.commission,   0);
   ArrayResize(real.swap,         0);
   ArrayResize(real.profit,       0);

   real.isOpenOrder      = false;
   real.isOpenPosition   = false;
   real.openLots         = 0;
   real.openSwap         = 0;
   real.openCommission   = 0;
   real.openPl           = 0;
   real.openPlNet        = 0;
   real.closedPositions  = 0;
   real.closedLots       = 0;
   real.closedSwap       = 0;
   real.closedCommission = 0;
   real.closedPl         = 0;
   real.closedPlNet      = 0;
   real.totalPlNet       = 0;

   // all closed positions
   int orders = OrdersHistoryTotal();
   for (int i=0; i < orders; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) return(!catch("ReadOrderLog(1)", ifIntOr(GetLastError(), ERR_RUNTIME_ERROR)));
      if (OrderMagicNumber() != orderMagicNumber) continue;
      if (OrderType() > OP_SELL)                  continue;
      if (OrderSymbol() != Symbol())              continue;

      if (!Orders.AddRealTicket(OrderTicket(), NULL, OrderLots(), OrderType(), OrderOpenTime(), OrderOpenPrice(), OrderCloseTime(), OrderClosePrice(), OrderStopLoss(), OrderTakeProfit(), OrderSwap(), OrderCommission(), OrderProfit()))
         return(false);
   }

   // all open orders
   orders = OrdersTotal();
   for (i=0; i < orders; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) return(!catch("ReadOrderLog(2)", ifIntOr(GetLastError(), ERR_RUNTIME_ERROR)));
      if (OrderMagicNumber() != orderMagicNumber) continue;
      if (OrderSymbol() != Symbol())              continue;

      if (!Orders.AddRealTicket(OrderTicket(), NULL, OrderLots(), OrderType(), OrderOpenTime(), OrderOpenPrice(), NULL, NULL, OrderStopLoss(), OrderTakeProfit(), OrderSwap(), OrderCommission(), OrderProfit()))
         return(false);
   }
   return(!catch("ReadOrderLog(3)"));
}


/**
 * Start the virtual trade copier.
 *
 * @return bool - success status
 */
bool StartTradeCopier() {
   if (IsLastError()) return(false);

   if (tradingMode == TRADINGMODE_VIRTUAL_MIRROR) {
      if (!CloseOpenOrders()) return(false);
      tradingMode = TRADINGMODE_VIRTUAL;
   }

   if (tradingMode == TRADINGMODE_VIRTUAL) {
      tradingMode = TRADINGMODE_VIRTUAL_COPIER;
      real.isSynchronized = false;                          // TODO: what else?
      return(!catch("StartTradeCopier(1)"));
   }

   return(!catch("StartTradeCopier(2)  cannot start trade copier in "+ TradingModeToStr(tradingMode), ERR_ILLEGAL_STATE));
}


/**
 * Start the virtual trade mirror.
 *
 * @return bool - success status
 */
bool StartTradeMirror() {
   if (IsLastError()) return(false);

   if (tradingMode == TRADINGMODE_VIRTUAL_COPIER) {
      if (!CloseOpenOrders()) return(false);
      tradingMode = TRADINGMODE_VIRTUAL;
   }

   if (tradingMode == TRADINGMODE_VIRTUAL) {
      tradingMode = TRADINGMODE_VIRTUAL_MIRROR;
      real.isSynchronized = false;                          // TODO: what else?
      return(!catch("StartTradeMirror(1)"));
   }

   return(!catch("StartTradeMirror(2)  cannot start trade mirror in "+ TradingModeToStr(tradingMode), ERR_ILLEGAL_STATE));
}


/**
 * Stop a running virtual trade copier/mirror.
 *
 * @return bool - success status
 */
bool StopVirtualTrading() {
   if (IsLastError()) return(false);

   if (tradingMode==TRADINGMODE_VIRTUAL_COPIER || tradingMode==TRADINGMODE_VIRTUAL_MIRROR) {
      if (!CloseOpenOrders()) return(false);
      tradingMode = TRADINGMODE_VIRTUAL;
      return(!catch("StopVirtualTrading(1)"));
   }

   return(!catch("StopVirtualTrading(2)  cannot stop virtual trading in "+ TradingModeToStr(tradingMode), ERR_ILLEGAL_STATE));
}


/**
 * Add a real order record to the order log and update statistics.
 *
 * @param  int      ticket
 * @param  int      linkedTicket
 * @param  double   lots
 * @param  int      type
 * @param  datetime openTime
 * @param  double   openPrice
 * @param  datetime closeTime
 * @param  double   closePrice
 * @param  double   stopLoss
 * @param  double   takeProfit
 * @param  double   swap
 * @param  double   commission
 * @param  double   profit
 *
 * @return bool - success status
 */
bool Orders.AddRealTicket(int ticket, int linkedTicket, double lots, int type, datetime openTime, double openPrice, datetime closeTime, double closePrice, double stopLoss, double takeProfit, double swap, double commission, double profit) {
   int pos = SearchIntArray(real.ticket, ticket);
   if (pos >= 0) return(!catch("Orders.AddRealTicket(1)  invalid parameter ticket: #"+ ticket +" (exists)", ERR_INVALID_PARAMETER));

   int pendingType, openType;
   double pendingPrice;

   if (IsPendingOrderType(type)) {
      pendingType  = type;
      pendingPrice = openPrice;
      openType     = OP_UNDEFINED;
      openTime     = NULL;
      openPrice    = NULL;
   }
   else {
      pendingType  = OP_UNDEFINED;
      pendingPrice = NULL;
      openType     = type;
   }

   int size=ArraySize(real.ticket), newSize=size+1;
   ArrayResize(real.ticket,       newSize); real.ticket      [size] = ticket;
   ArrayResize(real.linkedTicket, newSize); real.linkedTicket[size] = linkedTicket;
   ArrayResize(real.lots,         newSize); real.lots        [size] = lots;
   ArrayResize(real.pendingType,  newSize); real.pendingType [size] = pendingType;
   ArrayResize(real.pendingPrice, newSize); real.pendingPrice[size] = NormalizeDouble(pendingPrice, Digits);
   ArrayResize(real.openType,     newSize); real.openType    [size] = openType;
   ArrayResize(real.openTime,     newSize); real.openTime    [size] = openTime;
   ArrayResize(real.openPrice,    newSize); real.openPrice   [size] = NormalizeDouble(openPrice, Digits);
   ArrayResize(real.closeTime,    newSize); real.closeTime   [size] = closeTime;
   ArrayResize(real.closePrice,   newSize); real.closePrice  [size] = NormalizeDouble(closePrice, Digits);
   ArrayResize(real.stopLoss,     newSize); real.stopLoss    [size] = NormalizeDouble(stopLoss, Digits);
   ArrayResize(real.takeProfit,   newSize); real.takeProfit  [size] = NormalizeDouble(takeProfit, Digits);
   ArrayResize(real.commission,   newSize); real.commission  [size] = commission;
   ArrayResize(real.swap,         newSize); real.swap        [size] = swap;
   ArrayResize(real.profit,       newSize); real.profit      [size] = profit;

   bool _isOpenOrder      = (!closeTime);                                  // local vars
   bool _isPosition       = (openType != OP_UNDEFINED);
   bool _isOpenPosition   = (_isPosition && !closeTime);
   bool _isClosedPosition = (_isPosition && closeTime);

   if (_isOpenOrder) {
      if (real.isOpenOrder)    return(!catch("Orders.AddRealTicket(2)  cannot add open order #"+ ticket +" (another open order exists)", ERR_ILLEGAL_STATE));
      real.isOpenOrder = true;                                             // global vars
   }
   if (_isOpenPosition) {
      if (real.isOpenPosition) return(!catch("Orders.AddRealTicket(3)  cannot add open position #"+ ticket +" (another open position exists)", ERR_ILLEGAL_STATE));
      real.isOpenPosition = true;
      real.openLots       += ifDouble(IsLongOrderType(type), lots, -lots);
      real.openSwap       += swap;
      real.openCommission += commission;
      real.openPl         += profit;
      real.openPlNet       = real.openSwap + real.openCommission + real.openPl;
   }
   if (_isClosedPosition) {
      real.closedPositions++;
      real.closedLots       += lots;
      real.closedSwap       += swap;
      real.closedCommission += commission;
      real.closedPl         += profit;
      real.closedPlNet       = real.closedSwap + real.closedCommission + real.closedPl;
   }
   if (_isPosition) {
      real.totalPlNet = real.openPlNet + real.closedPlNet;
   }
   return(!catch("Orders.AddRealTicket(4)"));
}


/**
 * Add a virtual order record to the order log and update statistics.
 *
 * @param  _InOut_ int      &ticket - if 0 (NULL) a new ticket number is generated and assigned
 * @param  _In_    int      linkedTicket
 * @param  _In_    double   lots
 * @param  _In_    int      type
 * @param  _In_    datetime openTime
 * @param  _In_    double   openPrice
 * @param  _In_    datetime closeTime
 * @param  _In_    double   closePrice
 * @param  _In_    double   stopLoss
 * @param  _In_    double   takeProfit
 * @param  _In_    double   swap
 * @param  _In_    double   commission
 * @param  _In_    double   profit
 *
 * @return bool - success status
 */
bool Orders.AddVirtualTicket(int &ticket, int linkedTicket, double lots, int type, datetime openTime, double openPrice, datetime closeTime, double closePrice, double stopLoss, double takeProfit, double swap, double commission, double profit) {
   int pos = SearchIntArray(virt.ticket, ticket);
   if (pos >= 0) return(!catch("Orders.AddVirtualTicket(1)  invalid parameter ticket: #"+ ticket +" (exists)", ERR_INVALID_PARAMETER));

   int pendingType, openType;
   double pendingPrice;

   if (IsPendingOrderType(type)) {
      pendingType  = type;
      pendingPrice = openPrice;
      openType     = OP_UNDEFINED;
      openTime     = NULL;
      openPrice    = NULL;
   }
   else {
      pendingType  = OP_UNDEFINED;
      pendingPrice = NULL;
      openType     = type;
   }

   int size=ArraySize(virt.ticket), newSize=size+1;
   if (!ticket) {
      if (!size) ticket = 1;
      else       ticket = virt.ticket[size-1] + 1;
   }
   ArrayResize(virt.ticket,       newSize); virt.ticket      [size] = ticket;
   ArrayResize(virt.linkedTicket, newSize); virt.linkedTicket[size] = linkedTicket;
   ArrayResize(virt.lots,         newSize); virt.lots        [size] = lots;
   ArrayResize(virt.pendingType,  newSize); virt.pendingType [size] = pendingType;
   ArrayResize(virt.pendingPrice, newSize); virt.pendingPrice[size] = NormalizeDouble(pendingPrice, Digits);
   ArrayResize(virt.openType,     newSize); virt.openType    [size] = openType;
   ArrayResize(virt.openTime,     newSize); virt.openTime    [size] = openTime;
   ArrayResize(virt.openPrice,    newSize); virt.openPrice   [size] = NormalizeDouble(openPrice, Digits);
   ArrayResize(virt.closeTime,    newSize); virt.closeTime   [size] = closeTime;
   ArrayResize(virt.closePrice,   newSize); virt.closePrice  [size] = NormalizeDouble(closePrice, Digits);
   ArrayResize(virt.stopLoss,     newSize); virt.stopLoss    [size] = NormalizeDouble(stopLoss, Digits);
   ArrayResize(virt.takeProfit,   newSize); virt.takeProfit  [size] = NormalizeDouble(takeProfit, Digits);
   ArrayResize(virt.commission,   newSize); virt.commission  [size] = commission;
   ArrayResize(virt.swap,         newSize); virt.swap        [size] = swap;
   ArrayResize(virt.profit,       newSize); virt.profit      [size] = profit;

   bool _isOpenOrder      = (!closeTime);                                  // local vars
   bool _isPosition       = (openType != OP_UNDEFINED);
   bool _isOpenPosition   = (_isPosition && !closeTime);
   bool _isClosedPosition = (_isPosition && closeTime);

   if (_isOpenOrder) {
      if (virt.isOpenOrder)    return(!catch("Orders.AddVirtualTicket(2)  cannot add open order #"+ ticket +" (another open order exists)", ERR_ILLEGAL_STATE));
      virt.isOpenOrder = true;                                             // global vars
   }
   if (_isOpenPosition) {
      if (virt.isOpenPosition) return(!catch("Orders.AddVirtualTicket(3)  cannot add open position #"+ ticket +" (another open position exists)", ERR_ILLEGAL_STATE));
      virt.isOpenPosition = true;
      virt.openLots       += ifDouble(IsLongOrderType(type), lots, -lots);
      virt.openSwap       += swap;
      virt.openCommission += commission;
      virt.openPl         += profit;
      virt.openPlNet       = virt.openSwap + virt.openCommission + virt.openPl;
   }
   if (_isClosedPosition) {
      virt.closedPositions++;
      virt.closedLots       += lots;
      virt.closedSwap       += swap;
      virt.closedCommission += commission;
      virt.closedPl         += profit;
      virt.closedPlNet       = virt.closedSwap + virt.closedCommission + virt.closedPl;
   }
   if (_isPosition) {
      virt.totalPlNet = virt.openPlNet + virt.closedPlNet;
   }
   return(!catch("Orders.AddVirtualTicket(4)"));
}


/**
 * Remove a record from the order log.
 *
 * @param  int ticket - ticket of the record
 *
 * @return bool - success status
 */
bool Orders.RemoveTicket(int ticket) {
   int pos = SearchIntArray(real.ticket, ticket);
   if (pos < 0)                            return(!catch("Orders.RemoveTicket(1)  invalid parameter ticket: #"+ ticket +" (not found)", ERR_INVALID_PARAMETER));
   if (real.openType[pos] != OP_UNDEFINED) return(!catch("Orders.RemoveTicket(2)  cannot remove an opened position: #"+ ticket, ERR_ILLEGAL_STATE));
   if (!real.isOpenOrder)                  return(!catch("Orders.RemoveTicket(3)  real.isOpenOrder is FALSE", ERR_ILLEGAL_STATE));

   real.isOpenOrder = false;

   ArraySpliceInts   (real.ticket,       pos, 1);
   ArraySpliceInts   (real.linkedTicket, pos, 1);
   ArraySpliceDoubles(real.lots,         pos, 1);
   ArraySpliceInts   (real.pendingType,  pos, 1);
   ArraySpliceDoubles(real.pendingPrice, pos, 1);
   ArraySpliceInts   (real.openType,     pos, 1);
   ArraySpliceInts   (real.openTime,     pos, 1);
   ArraySpliceDoubles(real.openPrice,    pos, 1);
   ArraySpliceInts   (real.closeTime,    pos, 1);
   ArraySpliceDoubles(real.closePrice,   pos, 1);
   ArraySpliceDoubles(real.stopLoss,     pos, 1);
   ArraySpliceDoubles(real.takeProfit,   pos, 1);
   ArraySpliceDoubles(real.commission,   pos, 1);
   ArraySpliceDoubles(real.swap,         pos, 1);
   ArraySpliceDoubles(real.profit,       pos, 1);

   return(!catch("Orders.RemoveTicket(4)"));
}


/**
 * Whether a chart command was sent to the expert. If the case, the command is retrieved and returned.
 *
 * @param  string commands[] - array to store received commands
 *
 * @return bool
 */
bool EventListener_ChartCommand(string &commands[]) {
   if (!__isChart) return(false);

   static string label, mutex; if (!StringLen(label)) {
      label = ProgramName() +".command";
      mutex = "mutex."+ label;
   }

   // check for a command non-synchronized (read-only access) to prevent aquiring the lock on every tick
   if (ObjectFind(label) == 0) {
      // now aquire the lock for read-write access
      if (AquireLock(mutex, true)) {
         ArrayPushString(commands, ObjectDescription(label));
         ObjectDelete(label);
         return(ReleaseLock(mutex));
      }
   }
   return(false);
}


/**
 * Dispatch incoming commands.
 *
 * @param  string commands[] - received commands
 *
 * @return bool - success status of the executed command
 */
bool onCommand(string commands[]) {
   if (!ArraySize(commands)) return(!logWarn("onCommand(1)  empty parameter commands: {}"));
   string cmd = commands[0];
   debug("onCommand(0.1)  "+ cmd);

   // virtual
   if (cmd == "virtual") {
      switch (tradingMode) {
         case TRADINGMODE_VIRTUAL_COPIER:
         case TRADINGMODE_VIRTUAL_MIRROR:
            return(StopVirtualTrading());

         default: logWarn("onCommand(2)  cannot execute "+ DoubleQuoteStr(cmd) +" command in "+ TradingModeToStr(tradingMode));
      }
      return(true);
   }

   // virtual-copier
   if (cmd == "virtual-copier") {
      switch (tradingMode) {
         case TRADINGMODE_VIRTUAL:
         case TRADINGMODE_VIRTUAL_MIRROR:
            return(StartTradeCopier());

         default: logWarn("onCommand(3)  cannot execute "+ DoubleQuoteStr(cmd) +" command in "+ TradingModeToStr(tradingMode));
      }
      return(true);
   }

   // virtual-mirror
   if (cmd == "virtual-mirror") {
      switch (tradingMode) {
         case TRADINGMODE_VIRTUAL:
         case TRADINGMODE_VIRTUAL_COPIER:
            return(StartTradeMirror());

         default: logWarn("onCommand(4)  cannot execute "+ DoubleQuoteStr(cmd) +" command in "+ TradingModeToStr(tradingMode));
      }
      return(true);
   }

   return(!logWarn("onCommand(5)  unsupported command: "+ DoubleQuoteStr(cmd)));
}


/**
 * Generate a new sequence id. Must be unique for all running instances of this expert (strategy).
 *
 * @return int - sequence id in the range of 1000-16383
 */
int CreateSequenceId() {
   MathSrand(GetTickCount());                                  // TODO: also use window handle for the parameter
   int id;
   while (id < SID_MIN || id > SID_MAX) {
      id = MathRand();                                         // TODO: generate consecutive ids in tester
   }                                                           // TODO: test id for uniqueness
   return(id);
}


/**
 * Generate a unique magic order number for the sequence.
 *
 * @return int - magic number or NULL in case of errors
 */
int GenerateMagicNumber() {
   if (STRATEGY_ID & ( ~0x3FF) != 0) return(!catch("GenerateMagicNumber(1)  illegal strategy id: "+ STRATEGY_ID, ERR_ILLEGAL_STATE));
   if (sequence.id & (~0x3FFF) != 0) return(!catch("GenerateMagicNumber(2)  illegal sequence id: "+ sequence.id, ERR_ILLEGAL_STATE));

   int strategy = STRATEGY_ID;                                 // 101-1023   (10 bits)
   int sequence = sequence.id;                                 // 1000-16383 (14 bits)
                                                               // the remaining 8 bits are not used in this strategy
   return((strategy<<22) + (sequence<<8));
}


/**
 * Return the full name of the instance logfile.
 *
 * @return string - filename or an empty string in case of errors
 */
string GetLogFilename() {
   string name = GetStatusFilename();
   if (!StringLen(name)) return("");
   return(StrLeft(name, -3) +"log");
}


/**
 * Return the full name of the instance status file.
 *
 * @return string - filename or an empty string in case of errors
 */
string GetStatusFilename() {
   if (!sequence.id) return(_EMPTY_STR(catch("GetStatusFilename(1)  illegal sequence.id: "+ sequence.id, ERR_ILLEGAL_STATE)));
   static string sAccountCompany="", symbol=""; if (!StringLen(symbol)) {
      sAccountCompany = GetAccountCompany();
      symbol = Symbol();                                       // lock-in the original symbol in case of INITREASON_SYMBOLCHANGE
   }
   string directory = "\\presets\\" + ifString(IsTesting(), "Tester", sAccountCompany) +"\\";
   string baseName  = StrToLower(symbol) +".XMT-Scalper."+ sequence.id +".set";

   return(GetMqlFilesPath() + directory + baseName);
}


/**
 * Return a string representation of a virtual order record.
 *
 * @param  int  ticket
 *
 * @return string - string representation or an empty string in case of errors
 */
string DumpVirtualOrder(int ticket) {
   int i = SearchIntArray(virt.ticket, ticket);
   if (i < 0) return(_EMPTY_STR(catch("DumpVirtualOrder(1)  invalid parameter ticket: #"+ ticket +" (not found)", ERR_INVALID_PARAMETER)));

   string sLots         = NumberToStr(virt.lots[i], ".1+");
   string sPendingType  = ifString(virt.pendingType[i]==OP_UNDEFINED, "-", OrderTypeDescription(virt.pendingType[i]));
   string sPendingPrice = ifString(!virt.pendingPrice[i], "0", NumberToStr(virt.pendingPrice[i], PriceFormat));
   string sOpenType     = ifString(virt.openType[i]==OP_UNDEFINED, "-", OrderTypeDescription(virt.openType[i]));
   string sOpenTime     = ifString(!virt.openTime[i], "0", TimeToStr(virt.openTime[i], TIME_FULL));
   string sOpenPrice    = ifString(!virt.openPrice[i], "0", NumberToStr(virt.openPrice[i], PriceFormat));
   string sCloseTime    = ifString(!virt.closeTime[i], "0", TimeToStr(virt.closeTime[i], TIME_FULL));
   string sClosePrice   = ifString(!virt.closePrice[i], "0", NumberToStr(virt.closePrice[i], PriceFormat));
   string sTakeProfit   = ifString(!virt.takeProfit[i], "0", NumberToStr(virt.takeProfit[i], PriceFormat));
   string sStopLoss     = ifString(!virt.stopLoss[i], "0", NumberToStr(virt.stopLoss[i], PriceFormat));
   string sCommission   = DoubleToStr(virt.commission[i], 2);
   string sSwap         = DoubleToStr(virt.swap[i], 2);
   string sProfit       = DoubleToStr(virt.profit[i], 2);

   return("virtual #"+ ticket +": lots="+ sLots +", pendingType="+ sPendingType +", pendingPrice="+ sPendingPrice +", openType="+ sOpenType +", openTime="+ sOpenTime +", openPrice="+ sOpenPrice +", closeTime="+ sCloseTime +", closePrice="+ sClosePrice +", takeProfit="+ sTakeProfit +", stopLoss="+ sStopLoss +", commission="+ sCommission +", swap="+ sSwap +", profit="+ sProfit);
}


/**
 * Return a readable version of a trading mode.
 *
 * @param  int mode
 *
 * @return string
 */
string TradingModeToStr(int mode) {
   switch (mode) {
      case TRADINGMODE_REGULAR       : return("TRADINGMODE_REGULAR"       );
      case TRADINGMODE_VIRTUAL       : return("TRADINGMODE_VIRTUAL"       );
      case TRADINGMODE_VIRTUAL_COPIER: return("TRADINGMODE_VIRTUAL_COPIER");
      case TRADINGMODE_VIRTUAL_MIRROR: return("TRADINGMODE_VIRTUAL_MIRROR");
   }
   return(_EMPTY_STR(catch("TradingModeToStr(1)  invalid parameter mode: "+ mode, ERR_INVALID_PARAMETER)));
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

   string realStats="", virtStats="", copierStats="", mirrorStats="", sError="";
   if      (__STATUS_INVALID_INPUT) sError = StringConcatenate(" [",                 ErrorDescription(ERR_INVALID_INPUT_PARAMETER), "]");
   else if (__STATUS_OFF          ) sError = StringConcatenate(" [switched off => ", ErrorDescription(__STATUS_OFF.reason),         "]");

   string sSpreadInfo = "";
   if (currentSpread > MaxSpread || avgSpread > MaxSpread)
      sSpreadInfo = StringConcatenate("  =>  larger then MaxSpread of ", sMaxSpread);

   string msg = StringConcatenate(ProgramName(), sTradingModeDescriptions[tradingMode], "  (sid: ", sequence.id, ")", "           ", sError,                    NL,
                                                                                                                                                                NL,
                                    "Spread:    ",  sCurrentSpread, "    Avg: ", sAvgSpread, sSpreadInfo,                                                       NL,
                                    "BarSize:    ", sCurrentBarSize, "    MinBarSize: ", sMinBarSize,                                                           NL,
                                    "Channel:   ",  sIndicator,                                                                                                 NL,
                                    "Unitsize:   ", sUnitSize,                                                                                                  NL);

   if (tradingMode != TRADINGMODE_VIRTUAL) {
      realStats = StringConcatenate("Open:       ", NumberToStr(real.openLots, "+.+"),   " lot                           PL: ", DoubleToStr(real.openPlNet, 2), NL,
                                    "Closed:     ", real.closedPositions, " trades    ", NumberToStr(real.closedLots, ".+"), " lot    PL: ", DoubleToStr(real.closedPl, 2), "    Commission: ", DoubleToStr(real.closedCommission, 2), "    Swap: ", DoubleToStr(real.closedSwap, 2), NL,
                                    "Total PL:   ", DoubleToStr(real.totalPlNet, 2),                                                                            NL);
   }
   if (tradingMode != TRADINGMODE_REGULAR) {
      virtStats = StringConcatenate("Open:       ", NumberToStr(virt.openLots, "+.+"),   " lot                           PL: ", DoubleToStr(virt.openPlNet, 2), NL,
                                    "Closed:     ", virt.closedPositions, " trades    ", NumberToStr(virt.closedLots, ".+"), " lot    PL: ", DoubleToStr(virt.closedPl, 2), "    Commission: ", DoubleToStr(virt.closedCommission, 2), "    Swap: ", DoubleToStr(virt.closedSwap, 2), NL,
                                    "Total PL:   ", DoubleToStr(virt.totalPlNet, 2),                                                                            NL);
   }

   switch (tradingMode) {
      case TRADINGMODE_REGULAR:
         msg = StringConcatenate(msg,       NL,
                                 realStats, NL);
         break;

      case TRADINGMODE_VIRTUAL:
         msg = StringConcatenate(msg,       NL,
                                 virtStats, NL);
         break;

      case TRADINGMODE_VIRTUAL_COPIER:
         msg = StringConcatenate(msg,        NL,
                                 "Virtual",  NL,
                                 "--------", NL,
                                 virtStats,  NL,
                                 "Copier",   NL,
                                 "--------", NL,
                                 realStats,  NL);
         break;

      case TRADINGMODE_VIRTUAL_MIRROR:
         msg = StringConcatenate(msg,        NL,
                                 "Virtual",  NL,
                                 "--------", NL,
                                 virtStats,  NL,
                                 "Mirror",   NL,
                                 "-------",  NL,
                                 realStats,  NL);
         break;
   }

   // 3 lines margin-top for potential indicator legends
   Comment(NL, NL, NL, msg);
   if (__CoreFunction == CF_INIT) WindowRedraw();

   // store status in chart to enable remote control by scripts
   string label = "XMT-Scalper.status";
   if (ObjectFind(label) != 0) {
      ObjectCreate(label, OBJ_LABEL, 0, 0, 0);
      ObjectSet(label, OBJPROP_TIMEFRAMES, OBJ_PERIODS_NONE);
   }
   ObjectSetText(label, StringConcatenate(sequence.id, "|", TradingMode));

   if (!catch("ShowStatus(1)"))
      return(error);
   return(last_error);
}


/**
 * ShowStatus: Update all string representations.
 */
void SS.All() {
   if (__isChart) {
      SS.MinBarSize();
      SS.Spreads();
      SS.UnitSize();
   }
}


/**
 * ShowStatus: Update the string representation of the min. bar size.
 */
void SS.MinBarSize() {
   if (__isChart) {
      sMinBarSize = DoubleToStr(RoundCeil(minBarSize/Pip, 1), 1);
   }
}


/**
 * ShowStatus: Update the string representations of current and average spreads.
 */
void SS.Spreads() {
   if (__isChart) {
      sCurrentSpread = DoubleToStr(currentSpread, 1);

      if (IsTesting())     sAvgSpread = sCurrentSpread;
      else if (!avgSpread) sAvgSpread = "-";
      else                 sAvgSpread = DoubleToStr(avgSpread, 2);
   }
}


/**
 * ShowStatus: Update the string representation of the currently used lotsize.
 *
 * @param  double size [optional]
 */
void SS.UnitSize(double size = NULL) {
   if (__isChart) {
      static double lastSize = -1;

      if (size != lastSize) {
         if (!size) sUnitSize = "-";
         else       sUnitSize = NumberToStr(size, ".+") +" lot";
         lastSize = size;
      }
   }
}


/**
 * Return a string representation of the input parameters (for logging purposes).
 *
 * @return string
 */
string InputsToStr() {
   return("Sequence.ID="             + DoubleQuoteStr(Sequence.ID)                  +";"+ NL
         +"TradingMode="             + TradingMode                                  +";"+ NL

         +"EntryIndicator="          + EntryIndicator                               +";"+ NL
         +"IndicatorTimeframe="      + IndicatorTimeframe                           +";"+ NL
         +"IndicatorPeriods="        + IndicatorPeriods                             +";"+ NL
         +"BollingerBands.Deviation="+ NumberToStr(BollingerBands.Deviation, ".1+") +";"+ NL
         +"Envelopes.Deviation="     + NumberToStr(Envelopes.Deviation, ".1+")      +";"+ NL

         +"UseSpreadMultiplier="     + BoolToStr(UseSpreadMultiplier)               +";"+ NL
         +"SpreadMultiplier="        + NumberToStr(SpreadMultiplier, ".1+")         +";"+ NL
         +"MinBarSize="              + DoubleToStr(MinBarSize, 1)                   +";"+ NL

         +"BreakoutReversal="        + DoubleToStr(BreakoutReversal, 1)             +";"+ NL
         +"MaxSpread="               + DoubleToStr(MaxSpread, 1)                    +";"+ NL
         +"ReverseSignals="          + BoolToStr(ReverseSignals)                    +";"+ NL

         +"MoneyManagement="         + BoolToStr(MoneyManagement)                   +";"+ NL
         +"Risk="                    + NumberToStr(Risk, ".1+")                     +";"+ NL
         +"ManualLotsize="           + NumberToStr(ManualLotsize, ".1+")            +";"+ NL

         +"TakeProfit="              + DoubleToStr(TakeProfit, 1)                   +";"+ NL
         +"StopLoss="                + DoubleToStr(StopLoss, 1)                     +";"+ NL
         +"TrailEntryStep="          + DoubleToStr(TrailEntryStep, 1)               +";"+ NL
         +"TrailExitStart="          + DoubleToStr(TrailExitStart, 1)               +";"+ NL
         +"TrailExitStep="           + DoubleToStr(TrailExitStep, 1)                +";"+ NL
         +"MagicNumber="             + MagicNumber                                  +";"+ NL
         +"MaxSlippage="             + DoubleToStr(MaxSlippage, 1)                  +";"+ NL

         +"EA.StopOnProfit="         + DoubleToStr(EA.StopOnProfit, 2)              +";"+ NL
         +"EA.StopOnLoss="           + DoubleToStr(EA.StopOnLoss, 2)                +";"+ NL

         +"ChannelBug="              + BoolToStr(ChannelBug)                        +";"+ NL
         +"TakeProfitBug="           + BoolToStr(TakeProfitBug)                     +";"
   );

   // prevent compiler warnings
   DumpVirtualOrder(NULL);
}
