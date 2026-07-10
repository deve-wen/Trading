//+------------------------------------------------------------------+
//|                        EMA55MA233_ST_吞没_共振.mq5 |
//|  EMA55/MA233金叉死叉 + SuperTrend共振 + K线吞没形态入场            |
//|                                                                   |
//|  策略核心:                                                        |
//|  1. 趋势判断: EMA55上穿MA233=金叉多头 / EMA55下穿MA233=死叉空头  |
//|  2. SuperTrend同向确认 → 吞没形态入场                             |
//|  3. 每单固定SL/TP(带开关), 渐进式追踪/一次性保本二选一             |
//|  4. 连续亏损N次则暂停M分钟                                         |
//+------------------------------------------------------------------+
#property copyright "Senior Developer"
#property version   "4.00"
#property description "MA金叉死叉+SuperTrend共振+吞没入场+固定SL/TP+双套追踪"
#property description "① EMA55/MA233金叉=多头 死叉=空头 均线趋势"
#property description "② SuperTrend同向确认, 吞没形态共振入场"
#property description "③ 固定止损止盈(带开关), 追踪A/B二选一: A=渐进式 B=一次性保本"

#include <Trade\Trade.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| 输入参数                                                          |
//+------------------------------------------------------------------+
input group   "=== ★ 均线趋势参数 ==="
input int     InpMagicNumber     = 20260709;        // 魔法编号
input int     InpFastMAPeriod    = 55;              // 快线MA周期(EMA55)
input ENUM_MA_METHOD  InpFastMAMethod = MODE_EMA;   // 快线MA类型
input int     InpSlowMAPeriod    = 233;             // 慢线MA周期(MA233)
input ENUM_MA_METHOD  InpSlowMAMethod = MODE_SMA;   // 慢线MA类型
input ENUM_APPLIED_PRICE InpMAApplied = PRICE_CLOSE; // MA应用价格

input group   "=== ★ SuperTrend ==="
input bool    InpUseSuperTrend   = true;            // 启用SuperTrend共振确认
input int     InpSTPeriod        = 10;              // SuperTrend ATR周期
input double  InpSTMultiplier    = 3.0;             // SuperTrend倍数

input group   "=== ★ 开仓参数 ==="
input int     InpMinPullback     = 2;               // 最小连续回调K线数(吞没前) >=2

input group   "=== ★ 交易时间(北京时间) ==="
input int     InpGMTOffset       = 5;               // 服务器比北京晚N小时(MT5=5)
input int     InpStartHour       = 7;               // 交易开始 时(北京)
input int     InpStartMin        = 30;              // 交易开始 分(北京)
input int     InpEndHour         = 3;               // 交易结束 时(北京次日)
input int     InpEndMin          = 30;              // 交易结束 分(北京次日)

input group   "=== ★ 仓位管理 ==="
input bool    InpUseFixedLot     = true;            // true=固定手数 false=百分比
input double  InpFixedLot        = 0.01;            // 固定手数
input double  InpRiskPercent     = 1.0;             // 风险百分比(%)
input double  InpMinLot          = 0.01;            // 最小手数
input double  InpMaxLot          = 10.0;            // 最大手数

input group   "=== ★ 止损止盈开关 ==="
input bool    InpUseStopLoss     = true;            // 启用固定止损
input bool    InpUseTakeProfit   = true;            // 启用固定止盈

input group   "=== ★ 止损与追踪(共用基础参数) ==="
input int     InpSLPoints        = 300;             // 固定止损点数
input int     InpTPPoints        = 660;             // 固定止盈点数

input group   "=== ★ 追踪方式A: 渐进式(持续追踪SL,二选一) ==="
input bool    InpUseTrailA       = false;            // 启用追踪A(与B互斥)
input int     InpTrailA_Start    = 20;              // A: 追踪激活利润点数
input int     InpTrailA_Breakeven = 320;            // A: 保本点数(SL移入场价)

input group   "=== ★ 追踪方式B: 一次性保本(触发后锁死,二选一) ==="
input bool    InpUseTrailB       = false;            // 启用追踪B(与A互斥)
input int     InpTrailB_Trigger  = 320;             // B: 触发保本的利润点数
input int     InpTrailB_Safe     = 20;              // B: 保护利润(SL移开仓±此点数)

input group   "=== ★ 风控管理 ==="
input bool    InpUseDailyLoss    = true;            // 启用当日最大亏损限制
input double  InpDailyLossPct    = 5.0;             // 当日最大亏损(%)
input bool    InpUseSpreadLimit  = true;            // 启用点差限制
input int     InpMaxSpread       = 50;              // 最大允许点差

input group   "=== ★ 连续亏损暂停 ==="
input bool    InpUseCooldown     = true;            // 启用连续亏损暂停
input int     InpMaxConsecLoss   = 3;               // 连续亏损N次后暂停
input int     InpCooldownMins    = 90;              // 暂停时间(分钟)

//+------------------------------------------------------------------+
//| 全局对象                                                          |
//+------------------------------------------------------------------+
CTrade        m_trade;
CAccountInfo  m_account;

//--- 指标句柄
int           g_hFastMA   = INVALID_HANDLE; // 快线MA句柄(EMA55)
int           g_hSlowMA   = INVALID_HANDLE; // 慢线MA句柄(MA233)
int           g_hATR      = INVALID_HANDLE; // ATR句柄(用于SuperTrend)

//--- 趋势方向
int           g_trendDir  = 0;  // MA趋势: 1=多(金叉), -1=空(死叉)
int           g_stDir     = 0;  // SuperTrend方向: 1=多, -1=空

//--- 每Bar入场锁定
datetime      g_lastEntryBar  = 0;
datetime      g_lastCloseBarTime = 0;

//--- 连续亏损暂停
int           g_consecLossCount = 0;
datetime      g_cooldownUntil  = 0;
datetime      g_lastCooldownLog = 0;

//--- 日初权益
double        g_dailyEquity    = 0.0;
datetime      g_lastDayCheck   = 0;

//--- 追踪状态(两套共用同一订单列表)
ulong   g_trailTickets[10];       // 订单号
int     g_trailPersistCount = 0;

//--- 追踪方式A: 渐进式追踪状态
bool    g_trailA_activated[10];   // A: 是否已激活追踪
double  g_trailA_bestPrice[10];   // A: 追踪中的最优价格

//--- 追踪方式B: 一次性保本状态
bool    g_trailB_triggered[10];   // B: 是否已触发保本

//+------------------------------------------------------------------+
//| 点数→账户货币换算                                                |
//+------------------------------------------------------------------+
double PointsToDollars(double points, double volume)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0) return(0);
   return(points * volume * tickValue);
}

//+------------------------------------------------------------------+
//| 专家初始化函数                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 参数校验
   if(InpFastMAPeriod < 2) { Print("❌ 快线MA周期必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpSlowMAPeriod < 2) { Print("❌ 慢线MA周期必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpSTPeriod < 2)     { Print("❌ SuperTrend ATR周期必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpFixedLot <= 0 || InpMinLot <= 0 || InpMaxLot <= 0)
   {
      Print("❌ 手数参数必须>0"); return(INIT_PARAMETERS_INCORRECT);
   }

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(50);
   m_trade.SetAsyncMode(false);

   //--- 创建指标句柄
   g_hFastMA = iMA(_Symbol, _Period, InpFastMAPeriod, 0, InpFastMAMethod, InpMAApplied);
   if(g_hFastMA == INVALID_HANDLE) { Print("❌ 创建快线MA失败"); return(INIT_FAILED); }

   g_hSlowMA = iMA(_Symbol, _Period, InpSlowMAPeriod, 0, InpSlowMAMethod, InpMAApplied);
   if(g_hSlowMA == INVALID_HANDLE) { Print("❌ 创建慢线MA失败"); return(INIT_FAILED); }

   g_hATR = iATR(_Symbol, _Period, InpSTPeriod);
   if(g_hATR == INVALID_HANDLE) { Print("❌ 创建ATR失败"); return(INIT_FAILED); }

   //--- 预热
   int needBars = MathMax(InpSlowMAPeriod, InpSTPeriod + 50) + 10;
   if(Bars(_Symbol, _Period) < needBars)
   {
      Print("❌ K线数据不足, 需要至少", needBars, "根");
      return(INIT_FAILED);
   }

   //--- 初始化MA趋势方向
   double fast0[1], slow0[1];
   if(CopyBuffer(g_hFastMA, 0, 0, 1, fast0) >= 1 && CopyBuffer(g_hSlowMA, 0, 0, 1, slow0) >= 1)
      g_trendDir = (fast0[0] > slow0[0]) ? 1 : -1;
   else
      g_trendDir = 1;

   //--- 初始化SuperTrend
   UpdateSuperTrend();

   //--- 初始日权益
   UpdateDailyEquity();

   //--- 追踪方式互斥校验
   if(InpUseTrailA && InpUseTrailB)
   {
      Print("⚠️ 追踪A和B同时开启! 按A优先执行 (请只开启一个)");
   }

   EventSetTimer(1);

   Print("✅ EMA55MA233_ST_吞没 EA v4.00 启动");
   Print("   品种:", _Symbol, " 周期:", EnumToString(_Period));
   Print("   MA:", InpFastMAPeriod, "/", InpSlowMAPeriod, " ST周期:", InpSTPeriod, " 倍率:", InpSTMultiplier);
   Print("   初始趋势: MA=", (g_trendDir == 1 ? "多头" : "空头"),
         " ST=", (g_stDir == 1 ? "多头" : "空头"));
   Print("   SL:", InpSLPoints, "点 TP:", InpTPPoints, "点");
   if(InpUseTrailA)
      Print("   追踪方式A: 渐进式 (激活=", InpTrailA_Start, "点 保本=", InpTrailA_Breakeven, "点)");
   else if(InpUseTrailB)
      Print("   追踪方式B: 一次性保本 (触发=", InpTrailB_Trigger, "点 保护=", InpTrailB_Safe, "点)");
   else
      Print("   追踪: 关闭 (仅固定SL/TP)");
   Print("   交易时间 BJT ", InpStartHour, ":", StringFormat("%02d", InpStartMin),
         " ~ 次日", InpEndHour, ":", StringFormat("%02d", InpEndMin));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 专家反初始化函数                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_hFastMA != INVALID_HANDLE) IndicatorRelease(g_hFastMA);
   if(g_hSlowMA != INVALID_HANDLE) IndicatorRelease(g_hSlowMA);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   Print("🔴 EA停止, 原因代码:", reason);
}

//+------------------------------------------------------------------+
//| 定时器                                                            |
//+------------------------------------------------------------------+
void OnTimer() { OnTick(); }

//+------------------------------------------------------------------+
//| 更新MA趋势方向(金叉/死叉)                                         |
//+------------------------------------------------------------------+
void UpdateTrendDirection()
{
   double fast[3], slow[3];
   if(CopyBuffer(g_hFastMA, 0, 1, 3, fast) < 3) return;
   if(CopyBuffer(g_hSlowMA, 0, 1, 3, slow) < 3) return;

   // 金叉精确检测
   if(fast[0] > slow[0] && fast[1] <= slow[1])
   {
      if(g_trendDir != 1)
         Print("🔵 金叉! EMA55=", DoubleToString(fast[0],2), " > MA233=", DoubleToString(slow[0],2), " → 多头");
      g_trendDir = 1; return;
   }
   // 死叉精确检测
   if(fast[0] < slow[0] && fast[1] >= slow[1])
   {
      if(g_trendDir != -1)
         Print("🔴 死叉! EMA55=", DoubleToString(fast[0],2), " < MA233=", DoubleToString(slow[0],2), " → 空头");
      g_trendDir = -1; return;
   }
   // 位置一致性修正
   if(g_trendDir == 1 && fast[0] < slow[0]) { g_trendDir = -1; }
   else if(g_trendDir == -1 && fast[0] > slow[0]) { g_trendDir = 1; }
}

//+------------------------------------------------------------------+
//| 更新SuperTrend方向                                                |
//+------------------------------------------------------------------+
void UpdateSuperTrend()
{
   double atr[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1) return;
   if(atr[0] <= 0) return;

   double hl2 = (iHigh(_Symbol, _Period, 1) + iLow(_Symbol, _Period, 1)) / 2.0;
   double upperBand = hl2 + InpSTMultiplier * atr[0];
   double lowerBand = hl2 - InpSTMultiplier * atr[0];

   // --- 迭代计算SuperTrend方向(从远到近) ---
   int maxBars = MathMin(500, Bars(_Symbol, _Period) - InpSTPeriod - 5);
   if(maxBars < 30) return;

   int stDirBuf[500];
   double stLineBuf[500];

   // 从最远开始初始化: 假设上升趋势
   stDirBuf[maxBars - 1] = 1;
   stLineBuf[maxBars - 1] = lowerBand; // 初始ST线=下轨

   for(int i = maxBars - 2; i >= 1; i--)
   {
      double atrVal[1];
      if(CopyBuffer(g_hATR, 0, i, 1, atrVal) < 1) continue;
      if(atrVal[0] <= 0) continue;

      double h = iHigh(_Symbol, _Period, i);
      double l = iLow(_Symbol, _Period, i);
      double c = iClose(_Symbol, _Period, i);
      double hl2i = (h + l) / 2.0;

      double up = hl2i + InpSTMultiplier * atrVal[0];
      double dn = hl2i - InpSTMultiplier * atrVal[0];

      if(stDirBuf[i + 1] == 1) // 前一根是上升趋势
      {
         // 下轨取最大值(不降低)
         double newLower = (dn > stLineBuf[i + 1]) ? dn : stLineBuf[i + 1];
         stLineBuf[i] = newLower;
         if(c < newLower) { stDirBuf[i] = -1; } // 跌破下轨 → 翻转
         else { stDirBuf[i] = 1; }
      }
      else // 前一根是下降趋势
      {
         // 上轨取最小值(不降低)
         double newUpper = (up < stLineBuf[i + 1]) ? up : stLineBuf[i + 1];
         stLineBuf[i] = newUpper;
         if(c > newUpper) { stDirBuf[i] = 1; } // 突破上轨 → 翻转
         else { stDirBuf[i] = -1; }
      }
   }

   g_stDir = stDirBuf[1]; // 使用已完成K线(bar 1)的方向, 避免当前K线不稳定的干扰
}

//+------------------------------------------------------------------+
//| 吞没形态检测                                                      |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(int idx)
{
   double open2  = iOpen(_Symbol, _Period, idx);
   double close2 = iClose(_Symbol, _Period, idx);
   double open1  = iOpen(_Symbol, _Period, idx + 1);
   double close1 = iClose(_Symbol, _Period, idx + 1);

   if(close1 >= open1) return(false);
   if(close2 <= open2) return(false);
   if(!(open2 <= close1 && close2 >= open1)) return(false);

   for(int k = 1; k <= InpMinPullback; k++)
   {
      double o = iOpen(_Symbol, _Period, idx + k);
      double c = iClose(_Symbol, _Period, idx + k);
      if(c >= o) return(false);
   }
   return(true);
}

bool IsBearishEngulfing(int idx)
{
   double open2  = iOpen(_Symbol, _Period, idx);
   double close2 = iClose(_Symbol, _Period, idx);
   double open1  = iOpen(_Symbol, _Period, idx + 1);
   double close1 = iClose(_Symbol, _Period, idx + 1);

   if(close1 <= open1) return(false);
   if(close2 >= open2) return(false);
   if(!(open2 >= close1 && close2 <= open1)) return(false);

   for(int k = 1; k <= InpMinPullback; k++)
   {
      double o = iOpen(_Symbol, _Period, idx + k);
      double c = iClose(_Symbol, _Period, idx + k);
      if(c <= o) return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| 三共振入场检测                                                    |
//|  MA趋势 + SuperTrend(可选) + 吞没形态 → 返回开仓方向              |
//+------------------------------------------------------------------+
int CheckEngulfingEntry()
{
   // --- 条件1: MA趋势方向 ---
   if(g_trendDir == 0) return(0);

   // --- 条件2: SuperTrend同向确认(可选) ---
   if(InpUseSuperTrend && g_stDir != g_trendDir) return(0);

   // --- 条件3: 吞没形态 ---
   if(g_trendDir == 1 && IsBullishEngulfing(1)) return(1);
   if(g_trendDir == -1 && IsBearishEngulfing(1)) return(-1);

   return(0);
}

//+------------------------------------------------------------------+
//| 连续亏损停                                                                  |
//+------------------------------------------------------------------+
void OnPositionClosed(bool wasProfit)
{
   if(!InpUseCooldown) return;

   if(wasProfit)
   {
      if(g_consecLossCount > 0)
      {
         Print("📊 盈利平仓, 连续亏损清零 (之前:", g_consecLossCount, ")");
         g_consecLossCount = 0;
         g_cooldownUntil = 0;
      }
   }
   else
   {
      g_consecLossCount++;
      Print("📊 亏损关闭, 连续亏损:", g_consecLossCount, "/", InpMaxConsecLoss);
      if(g_consecLossCount >= InpMaxConsecLoss)
      {
         g_cooldownUntil = TimeCurrent() + InpCooldownMins * 60;
         Print("🚫 连续", g_consecLossCount, "次亏损, 暂停至 ", TimeToString(g_cooldownUntil));
      }
   }
}

//+------------------------------------------------------------------+
//| 追踪统一入口(二选一: A优先于B)                                    |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| 追踪统一入口(二选一: A优先于B)                                    |
//+------------------------------------------------------------------+
void ProcessPositionSLTrailing()
{
   if(InpUseTrailA)       { ProcessTrailA(); return; }
   else if(InpUseTrailB)  { ProcessTrailB(); return; }
}

//+------------------------------------------------------------------+
//| 查找/创建订单追踪索引(共用)                                       |
//+------------------------------------------------------------------+
int FindOrCreateTrailIdx(ulong ticket)
{
   for(int t = 0; t < g_trailPersistCount; t++)
      if(g_trailTickets[t] == ticket) return(t);

   if(g_trailPersistCount >= 10) return(-1);
   int idx = g_trailPersistCount;
   g_trailTickets[idx] = ticket;
   g_trailA_activated[idx] = false;
   g_trailA_bestPrice[idx] = 0;
   g_trailB_triggered[idx] = false;
   g_trailPersistCount++;
   return(idx);
}

//+------------------------------------------------------------------+
//| 追踪方式A: 渐进式(持续追踪SL)                                     |
//| 利润≥Start点激活 → 持续追踪bestPrice → 利润≥Breakeven点SL移入场价 |
//+------------------------------------------------------------------+
void ProcessTrailA()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionGetTicket(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ulong ticket = PositionGetTicket(i);
      int    posType = (int)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice = (posType == POSITION_TYPE_BUY) ?
                        SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                        SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currSL = PositionGetDouble(POSITION_SL);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double profitPts = (tickValue > 0) ? profit / (volume * tickValue) : 0;

      int tIdx = FindOrCreateTrailIdx(ticket);
      if(tIdx < 0) continue;

      if(!g_trailA_activated[tIdx] && profitPts >= InpTrailA_Start)
      {
         g_trailA_activated[tIdx] = true;
         g_trailA_bestPrice[tIdx] = curPrice;
         Print("🔔 [追踪A] 激活 #", ticket, " 利润=", DoubleToString(profitPts,1), "点");
      }

      if(!g_trailA_activated[tIdx]) continue;

      if(posType == POSITION_TYPE_BUY && curPrice > g_trailA_bestPrice[tIdx])
         g_trailA_bestPrice[tIdx] = curPrice;
      else if(posType == POSITION_TYPE_SELL && curPrice < g_trailA_bestPrice[tIdx])
         g_trailA_bestPrice[tIdx] = curPrice;

      double trailSL = g_trailA_bestPrice[tIdx] -
                       (posType == POSITION_TYPE_BUY ? 1 : -1) * InpTrailA_Breakeven * tickSize;
      double stopLimit = openPrice -
                         (posType == POSITION_TYPE_BUY ? 1 : -1) * InpSLPoints * tickSize;
      double newSL = (posType == POSITION_TYPE_BUY) ?
                     fmax(stopLimit, trailSL) : fmin(stopLimit, trailSL);

      bool needModify = false;
      if(posType == POSITION_TYPE_BUY && newSL > currSL) needModify = true;
      if(posType == POSITION_TYPE_SELL && (currSL == 0 || newSL < currSL)) needModify = true;

      if(needModify)
      {
         if(m_trade.PositionModify(ticket, newSL, 0))
            Print("   [追踪A] SL更新 #", ticket, " → ", DoubleToString(newSL, _Digits),
                  " (利润=", DoubleToString(profitPts,1), "点)");
      }
   }
}

//+------------------------------------------------------------------+
//| 追踪方式B: 一次性保本(触发后锁死)                                  |
//| 利润≥Trigger点时, SL移到开仓±Safe点, 之后不再移动                  |
//+------------------------------------------------------------------+
void ProcessTrailB()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionGetTicket(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ulong ticket = PositionGetTicket(i);
      int    posType = (int)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currSL = PositionGetDouble(POSITION_SL);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double profitPts = (tickValue > 0) ? profit / (volume * tickValue) : 0;

      int tIdx = FindOrCreateTrailIdx(ticket);
      if(tIdx < 0) continue;

      if(g_trailB_triggered[tIdx]) continue;

      if(profitPts >= InpTrailB_Trigger)
      {
         double safeSL = openPrice;
         if(posType == POSITION_TYPE_BUY)
            safeSL = openPrice + InpTrailB_Safe * tickSize;
         else
            safeSL = openPrice - InpTrailB_Safe * tickSize;

         bool needModify = false;
         if(posType == POSITION_TYPE_BUY && safeSL > currSL) needModify = true;
         if(posType == POSITION_TYPE_SELL && (currSL == 0 || safeSL < currSL)) needModify = true;

         if(needModify)
         {
            if(m_trade.PositionModify(ticket, safeSL, 0))
            {
               g_trailB_triggered[tIdx] = true;
               Print("🔒 [追踪B] 保本锁定 #", ticket, " SL→", DoubleToString(safeSL, _Digits),
                     " (利润=", DoubleToString(profitPts,1), "点, 保固=", InpTrailB_Safe, "点)");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Tick事件 - 主逻辑                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1) 交易时间
   if(!IsTradingTime()) return;

   datetime completedBarTime = iTime(_Symbol, _Period, 1);

   //--- 2) 每日权益
   UpdateDailyEquity();
   if(InpUseDailyLoss && CheckDailyLossReached()) return;

   //--- 3) 点差
   if(InpUseSpreadLimit)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpread) return;
   }

   //--- 4) 更新趋势方向
   UpdateTrendDirection();

   //--- 5) 更新SuperTrend方向
   UpdateSuperTrend();

   //--- 6) 追踪止损(必须在开仓前处理)
   ProcessPositionSLTrailing();

   //--- 7) 吞没形态 + 共振信号
   int signalDir = CheckEngulfingEntry();

   //--- 诊断日志(每10秒)
   static datetime lastLog = 0;
   if(TimeCurrent() - lastLog >= 10)
   {
      lastLog = TimeCurrent();
      double fastMA[1], slowMA[1];
      CopyBuffer(g_hFastMA, 0, 1, 1, fastMA);
      CopyBuffer(g_hSlowMA, 0, 1, 1, slowMA);
      string engulfInfo = "";
      if(IsBullishEngulfing(1)) engulfInfo = "多头吞没";
      else if(IsBearishEngulfing(1)) engulfInfo = "空头吞没";
      else engulfInfo = "无";
      string maStr = (g_trendDir == 1) ? "↑多" : ((g_trendDir == -1) ? "↓空" : "---");
      string stStr  = (g_stDir == 1) ? "↑多" : ((g_stDir == -1) ? "↓空" : "---");

      Print(StringFormat("[诊断] Fast:%.2f Slow:%.2f MA:%s ST:%s 吞没:%s 信号:%s 持仓:%d",
            fastMA[0], slowMA[0], maStr, stStr, engulfInfo,
            signalDir == 1 ? "↑" : (signalDir == -1 ? "↓" : "无"),
            PositionsTotal()));
   }

   //--- 8) 入场(无持仓且无暂停)
   if(PositionsTotal() > 0) return;

   // 暂停检查
   if(InpUseCooldown && TimeCurrent() < g_cooldownUntil)
   {
      if(TimeCurrent() - g_lastCooldownLog >= 60)
      {
         g_lastCooldownLog = TimeCurrent();
         int remain = (int)(g_cooldownUntil - TimeCurrent()) / 60;
         Print("⏳ 暂停中, 剩余约", remain, "分钟");
      }
      return;
   }

   // 同Bar平仓保护
   if(completedBarTime == g_lastCloseBarTime) return;

   // 三共振入场
   if(signalDir != 0 && completedBarTime != g_lastEntryBar)
   {
      OpenPosition(signalDir);
      g_lastEntryBar = completedBarTime;
   }
}

//+------------------------------------------------------------------+
//| 计算手数                                                          |
//+------------------------------------------------------------------+
double CalcLot()
{
   double baseLot;
   if(InpUseFixedLot)
      baseLot = InpFixedLot;
   else
   {
      baseLot = m_account.Equity() * InpRiskPercent / 10000.0;
      if(baseLot < InpMinLot) baseLot = InpMinLot;
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) baseLot = MathRound(baseLot / step) * step;
   if(baseLot < InpMinLot) baseLot = InpMinLot;
   if(baseLot > InpMaxLot) baseLot = InpMaxLot;

   // 保证金检查
   double margin = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, baseLot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin))
   {
      double freeMargin = m_account.FreeMargin();
      if(margin > freeMargin * 0.8)
      {
         baseLot = MathFloor(freeMargin * 0.7 / margin * baseLot / step) * step;
         if(baseLot < InpMinLot) baseLot = InpMinLot;
      }
   }
   return(baseLot);
}

//+------------------------------------------------------------------+
//| 开仓                                                              |
//+------------------------------------------------------------------+
void OpenPosition(int direction)
{
   double lot = CalcLot();
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) { Print("❌ 获取tickSize失败"); return; }

   double price = 0.0;
   double sl = 0.0, tp = 0.0;
   string comment = StringFormat("MAST_E_%d_%s", (int)TimeCurrent(), direction == 1 ? "B" : "S");

   if(direction == 1) // Buy
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(InpUseStopLoss)  sl = price - InpSLPoints * tickSize;
      if(InpUseTakeProfit) tp = price + InpTPPoints * tickSize;
      if(m_trade.Buy(lot, _Symbol, price, sl, tp, comment))
      {
         Print("🟢 开多 手数=", lot, " SL=", (InpUseStopLoss ? DoubleToString(sl,2) : "关"),
               " TP=", (InpUseTakeProfit ? DoubleToString(tp,2) : "关"));
      }
   }
   else // Sell
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(InpUseStopLoss)  sl = price + InpSLPoints * tickSize;
      if(InpUseTakeProfit) tp = price - InpTPPoints * tickSize;
      if(m_trade.Sell(lot, _Symbol, price, sl, tp, comment))
      {
         Print("🔴 开空 手数=", lot, " SL=", (InpUseStopLoss ? DoubleToString(sl,2) : "关"),
               " TP=", (InpUseTakeProfit ? DoubleToString(tp,2) : "关"));
      }
   }
}

//+------------------------------------------------------------------+
//| 交易时间检查                                                      |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);

   int bjHour = dt.hour + InpGMTOffset;
   int bjMin  = dt.min;
   if(bjHour >= 24) bjHour -= 24;

   int bjMinutes = bjHour * 60 + bjMin;
   int startMin  = InpStartHour * 60 + InpStartMin;
   int endMin    = InpEndHour * 60 + InpEndMin;

   if(endMin <= startMin) endMin += 24 * 60;
   if(bjMinutes < startMin) bjMinutes += 24 * 60;

   return(bjMinutes >= startMin && bjMinutes <= endMin);
}

//+------------------------------------------------------------------+
//| 日初权益                                                          |
//+------------------------------------------------------------------+
void UpdateDailyEquity()
{
   MqlDateTime today;
   TimeToStruct(TimeCurrent(), today);
   today.hour = 0; today.min = 0; today.sec = 0;
   datetime dayStart = StructToTime(today);

   if(dayStart != g_lastDayCheck)
   {
      g_lastDayCheck = dayStart;
      g_dailyEquity = m_account.Equity();
   }
}

//+------------------------------------------------------------------+
//| 亏损上限                                                          |
//+------------------------------------------------------------------+
bool CheckDailyLossReached()
{
   if(g_dailyEquity <= 0) return(false);
   double lossPct = (g_dailyEquity - m_account.Equity()) / g_dailyEquity * 100.0;
   static bool warned = false;

   if(lossPct >= InpDailyLossPct)
   {
      if(!warned)
      {
         Print("🚫 当日亏损 ", DoubleToString(lossPct, 1), "% (上限", InpDailyLossPct, "%), 禁止开仓!");
         warned = true;
      }
      return(true);
   }
   if(lossPct < InpDailyLossPct * 0.8) warned = false;
   return(false);
}

//+------------------------------------------------------------------+
//| Chart事件                                                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CLICK)
   {
      int pos = PositionsTotal();
      string info = StringFormat("📊 持仓:%d | 趋势:MA=%s ST=%s | 连续亏损:%d | 暂停:%s",
            pos,
            g_trendDir == 1 ? "多" : (g_trendDir == -1 ? "空" : "无"),
            g_stDir == 1 ? "多" : (g_stDir == -1 ? "空" : "无"),
            g_consecLossCount,
            (InpUseCooldown && TimeCurrent() < g_cooldownUntil) ? "是" : "否");
      Print(info);
   }
}
//+------------------------------------------------------------------+
