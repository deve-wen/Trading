//+------------------------------------------------------------------+
//|                                          EMA55_吞没_倍投.mq5 |
//|  EMA55趋势 + K线吞没形态开仓 + 逆势倍投(马丁格尔)                 |
//|                                                                   |
//|  策略核心:                                                        |
//|  1. EMA55趋势判断: 价格>EMA55=多头 / 价格<EMA55=空头              |
//|  2. 顺势吞没形态入场:                                              |
//|     多头: 回调阴线→被阳线吞没→收盘开多                            |
//|     空头: 反弹阳线→被阴线吞没→收盘开空                            |
//|  3. 每单独立点数止损(亏损N点平仓, XAUUSD 0.01手=300点=3$)     |
//|  4. 连续亏损N次则暂停M分钟                                         |
//|  5. 趋势反转时2x倍投(也需吞没形态确认), 同组总点数达标全部平仓    |
//+------------------------------------------------------------------+
#property copyright "Senior Developer"
#property version   "2.02"
#property description "EMA55趋势+K线吞没形态开仓+逆势倍投"
#property description "① 价格>EMA55=多头 价格<EMA55=空头"
#property description "② 多头:阴线被阳线吞没→开多 | 空头:阳线被阴线吞没→开空"
#property description "③ 点数止损+点数追踪止损+连续亏损暂停"
#property description "④ 趋势反转+吞没形态=2x逆势倍投,最高N次(默认3次)"

#include <Trade\Trade.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| 输入参数 - 核心策略                                               |
//+------------------------------------------------------------------+
input group   "=== ★ 核心策略参数 ==="
input int     InpMagicNumber     = 20260629;        // 魔法编号
input int     InpEMAPeriod       = 55;              // EMA周期
input ENUM_MA_METHOD  InpEMAMethod = MODE_EMA;      // EMA类型
input ENUM_APPLIED_PRICE InpEMAApplied = PRICE_CLOSE; // EMA应用价格

input group   "=== ★ 开仓与倍投 ==="
input double  InpTPPoints        = 660;             // 同组总利润达标点数(如XAUUSD 0.01手=6.6$)
input int     InpMaxDoubles      = 3;               // 最高倍投次数(0=不倍投)
input int     InpMinPullback     = 2;               // 最小连续回调K线数(吞没前) >=2

input group   "=== ★ 交易时间(北京时间) ==="
input int     InpGMTOffset       = 5;               // 服务器比北京晚N小时(MT5=5)
input int     InpStartHour       = 7;               // 交易开始 时(北京)
input int     InpStartMin        = 30;              // 交易开始 分(北京)
input int     InpEndHour         = 3;               // 交易结束 时(北京次日)
input int     InpEndMin          = 30;              // 交易结束 分(北京次日)

input group   "=== ★ 仓位管理 ==="
input bool    InpUseFixedLot     = true;            // true=固定手数 false=百分比
input double  InpFixedLot        = 0.01;            // 固定手数(首单)
input double  InpRiskPercent     = 1.0;             // 风险百分比(%)
input double  InpMinLot          = 0.01;            // 最小手数
input double  InpMaxLot          = 10.0;            // 最大手数

input group   "=== ★ 风控管理 ==="
input bool    InpUseDailyLoss    = true;            // 启用当日最大亏损限制
input double  InpDailyLossPct    = 5.0;             // 当日最大亏损(%)
input bool    InpUseSpreadLimit  = true;            // 启用点差限制
input int     InpMaxSpread       = 50;              // 最大允许点差

input group   "=== ★ 连续亏损暂停 ==="
input bool    InpUseCooldown     = true;            // 启用连续亏损暂停
input int     InpMaxConsecLoss   = 3;               // 连续亏损N次后暂停
input int     InpCooldownMins    = 90;              // 暂停时间(分钟)

input group   "=== ★ 止损与追踪(每单独立) ==="
input bool    InpUseStopLoss     = true;            // 启用单笔止损(亏N点平仓)
input double  InpSLPoints        = 300;             // 单笔最大亏损点数(如XAUUSD 0.01手=3$)
input bool    InpUseTrailing     = true;            // 启用追踪止损
input double  InpTrailActivatePoints = 300;         // 追踪激活利润点数(如XAUUSD 0.01手=3$)
input double  InpTrailDistancePoints = 200;         // 追踪回撤距离点数(如XAUUSD 0.01手=2$)

//+------------------------------------------------------------------+
//| 全局对象                                                         |
//+------------------------------------------------------------------+
CTrade        m_trade;
CAccountInfo  m_account;

//--- 指标句柄
int           g_hEMA   = INVALID_HANDLE;  // EMA指标句柄

//+------------------------------------------------------------------+
//| 组状态结构 - 一个同组交易内的所有信息                             |
//+------------------------------------------------------------------+
struct GroupState
{
   bool   active;          // 是否有活跃组
   int    groupID;         // 组ID(TimeCurrent创建时)
   int    baseDir;         // 首单方向: 1=Buy, -1=Sell
   int    currentLevel;    // 当前最高层级(-1=无单, 0=首单, 1=第1次倍投...)
   ulong  tickets[4];      // 各层级订单票据(0~InpMaxDoubles, max 4)
   double lots[4];         // 各层级手数
   int    dirs[4];         // 各层级方向: 1=Buy, -1=Sell

   GroupState() { Reset(); }

   void Reset()
   {
      active       = false;
      groupID      = 0;
      baseDir      = 0;
      currentLevel = -1;
      for(int i = 0; i < 4; i++)
      {
         tickets[i] = 0;
         lots[i]    = 0.0;
         dirs[i]    = 0;
      }
   }
};
GroupState g_group;

//--- 每Bar入场锁定(每个完成K线最多触发一次)
datetime g_lastEntryBar  = 0;  // 最近一次开首单的完成K线时间
datetime g_lastDoubleBar = 0;  // 最近一次倍投的完成K线时间

//--- 同Bar平仓后禁开(同一K线上平仓则不再开新单)
datetime g_lastCloseBarTime = 0;

//--- 连续亏损暂停
int g_consecLossCount = 0;       // 当前连续亏损次数
datetime g_cooldownUntil = 0;    // 暂停截止时间(0=无暂停)

//--- 日初权益(用于计算当日亏损)
double g_dailyEquity = 0.0;
datetime g_lastDayCheck = 0;

//+------------------------------------------------------------------+
//| 追踪止损状态(每单独立)                                            |
//+------------------------------------------------------------------+
struct TrailState
{
   ulong  ticket;       // 持仓票据
   bool   activated;    // 是否已激活(利润>=阈值)
   double bestPrice;    // 多单=Bid最高价 / 空单=Ask最低价
   int    direction;    // 1=多, -1=空
};
TrailState g_trails[10]; // 最多同时追踪10个持仓
int g_trailCount = 0;

//--- 追踪止损持久化数组(替代函数内的static数组, MQL5不支持局部static数组)
ulong   g_trailTickets[10];
double  g_trailBestPrices[10];
bool    g_trailActivated[10];
int     g_trailPersistCount = 0;

//--- 连续亏损暂停日志(替代嵌套块内的static, MQL5不支持块级static)
datetime g_lastCooldownLog = 0;

//--- 组重建用的临时结构体(MQL5不支持函数内局部struct)
struct TempPos { ulong ticket; int level; int dir; double lot; };

//+------------------------------------------------------------------+
//| 点数→账户货币换算(1点 = 1个tickSize)                              |
//|  XAUUSD 0.01手: 1点(0.01价格) = tickValue * 0.01 = 0.01$          |
//+------------------------------------------------------------------+
double PointsToDollars(double points, double volume)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0) return(0);
   return(points * volume * tickValue);
}

//+------------------------------------------------------------------+
//| 获取同组总持仓手数                                                |
//+------------------------------------------------------------------+
double GetGroupTotalVolume()
{
   double total = 0.0;
   for(int i = 0; i <= g_group.currentLevel; i++)
   {
      if(g_group.tickets[i] > 0 && PositionSelectByTicket(g_group.tickets[i]))
         total += PositionGetDouble(POSITION_VOLUME);
   }
   return(total);
}

//+------------------------------------------------------------------+
//| 专家初始化函数                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 参数校验
   if(InpEMAPeriod < 2) { Print("❌ EMA周期必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpMaxDoubles < 0 || InpMaxDoubles > 3)
   {
      Print("❌ 最高倍投次数范围为0~3"); return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpFixedLot <= 0 || InpMinLot <= 0 || InpMaxLot <= 0)
   {
      Print("❌ 手数参数必须>0"); return(INIT_PARAMETERS_INCORRECT);
   }

   //--- 设置交易参数
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(50);
   m_trade.SetAsyncMode(false);

   //--- 创建EMA指标句柄
   g_hEMA = iMA(_Symbol, _Period, InpEMAPeriod, 0, InpEMAMethod, InpEMAApplied);
   if(g_hEMA == INVALID_HANDLE)
   {
      Print("❌ 创建EMA指标失败"); return(INIT_FAILED);
   }

   //--- 预热指标数据
   if(Bars(_Symbol, _Period) < InpEMAPeriod + 10)
   {
      Print("❌ K线数据不足, 需要至少", InpEMAPeriod + 10, "根K线");
      return(INIT_FAILED);
   }

   //--- 恢复组状态
   RebuildGroupFromPositions();

   //--- 初始化日初权益
   UpdateDailyEquity();

   //--- 定时器
   EventSetTimer(1);

   //--- 打印启动信息
   Print("✅ EMA55_吞没_倍投 EA v2.02 启动");
   Print("   交易品种: ", _Symbol, " | 周期: ", EnumToString(_Period));
   Print("   EMA:", InpEMAPeriod, " | 同组TP:", InpTPPoints, "点 | 最高倍投:", InpMaxDoubles, "次 | 最小回调:", InpMinPullback, "根");
   if(InpUseStopLoss)
      Print("   止损: 开启 | 每单亏损-", InpSLPoints, "点平仓");
   else
      Print("   止损: 关闭");
   if(InpUseTrailing)
      Print("   追踪: 开启 | 利润>", InpTrailActivatePoints, "点激活, 回撤>", InpTrailDistancePoints, "点平仓");
   else
      Print("   追踪: 关闭");
   Print("   北京时间 ", InpStartHour, ":", StringFormat("%02d", InpStartMin),
         " ~ 次日", InpEndHour, ":", StringFormat("%02d", InpEndMin));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 专家反初始化函数                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_hEMA != INVALID_HANDLE) { IndicatorRelease(g_hEMA); g_hEMA = INVALID_HANDLE; }
   Print("🔴 EA停止, 原因代码:", reason);
}

//+------------------------------------------------------------------+
//| 定时器事件                                                       |
//+------------------------------------------------------------------+
void OnTimer()
{
   OnTick();
}

//+------------------------------------------------------------------+
//| 多空吞没形态检测                                                  |
//|  idx = 完成K线索引(1=最新完成)                                    |
//|  多头吞没: idx处为阳线(close>open), idx+1处为阴线(close<open)     |
//|            阳线实体完整覆盖阴线实体                                |
//|  空头吞没: idx处为阴线(close<open), idx+1处为阳线(close>open)     |
//|            阴线实体完整覆盖阳线实体                                |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(int idx)
{
   double open2  = iOpen(_Symbol, _Period, idx);     // 当前K线(吞没方)
   double close2 = iClose(_Symbol, _Period, idx);
   double open1  = iOpen(_Symbol, _Period, idx + 1); // 前一根K线(被吞没方)
   double close1 = iClose(_Symbol, _Period, idx + 1);

   // idx+1 必须为阴线(close < open) → 代表回调
   if(close1 >= open1) return(false);

   // idx 必须为阳线(close > open) → 代表趋势恢复
   if(close2 <= open2) return(false);

   // 阳线实体完全覆盖阴线实体
   if(!(open2 <= close1 && close2 >= open1)) return(false);

   // ★ 新增: 检查是否至少有 InpMinPullback 根连续阴线(包含被吞没的那根)
   //    即 idx+1 到 idx+InpMinPullback 都是阴线
   for(int k = 1; k <= InpMinPullback; k++)
   {
      double o = iOpen(_Symbol, _Period, idx + k);
      double c = iClose(_Symbol, _Period, idx + k);
      if(c >= o) return(false); // 不是阴线 → 连续回调不够
   }

   return(true);
}

bool IsBearishEngulfing(int idx)
{
   double open2  = iOpen(_Symbol, _Period, idx);     // 当前K线(吞没方)
   double close2 = iClose(_Symbol, _Period, idx);
   double open1  = iOpen(_Symbol, _Period, idx + 1); // 前一根K线(被吞没方)
   double close1 = iClose(_Symbol, _Period, idx + 1);

   // idx+1 必须为阳线(close > open) → 代表反弹
   if(close1 <= open1) return(false);

   // idx 必须为阴线(close < open) → 代表趋势恢复
   if(close2 >= open2) return(false);

   // 阴线实体完全覆盖阳线实体
   if(!(open2 >= close1 && close2 <= open1)) return(false);

   // ★ 新增: 检查是否至少有 InpMinPullback 根连续阳线(包含被吞没的那根)
   for(int k = 1; k <= InpMinPullback; k++)
   {
      double o = iOpen(_Symbol, _Period, idx + k);
      double c = iClose(_Symbol, _Period, idx + k);
      if(c <= o) return(false); // 不是阳线 → 连续反弹不够
   }

   return(true);
}

//+------------------------------------------------------------------+
//| 吞没入场方向检测 - 返回 1=多, -1=空, 0=无信号                    |
//+------------------------------------------------------------------+
int CheckEngulfingEntry(double emaVal)
{
   // 趋势方向: 基于完成K线close vs EMA (稳定)
   double close1 = iClose(_Symbol, _Period, 1); // 最新完成K线收盘
   bool trendBull = (close1 > emaVal);
   bool trendBear = (close1 < emaVal);

   // 多头入场: 上升趋势 + 多头吞没形态
   if(trendBull && IsBullishEngulfing(1))
      return(1);

   // 空头入场: 下降趋势 + 空头吞没形态
   if(trendBear && IsBearishEngulfing(1))
      return(-1);

   return(0);
}

//+------------------------------------------------------------------+
//| 连续亏损暂停: 组关闭时调用                                          |
//|  wasTP = true  → 组止盈达标(盈利), 重置连续亏损计数                 |
//|  wasTP = false → 组被止损/异常关闭(亏损), 递增计数, 达上限则暂停   |
//+------------------------------------------------------------------+
void OnGroupClosed(bool wasTP)
{
   if(!InpUseCooldown) return;

   if(wasTP)
   {
      // 盈利→重置
      if(g_consecLossCount > 0)
      {
         Print("📊 组盈利平仓, 连续亏损计数清零 (之前:", g_consecLossCount, ")");
         g_consecLossCount = 0;
         g_cooldownUntil = 0;
      }
   }
   else
   {
      g_consecLossCount++;
      Print("📊 组亏损关闭, 连续亏损:", g_consecLossCount, "/", InpMaxConsecLoss);

      if(g_consecLossCount >= InpMaxConsecLoss)
      {
         g_cooldownUntil = TimeCurrent() + InpCooldownMins * 60;
         Print("🚫 连续", g_consecLossCount, "次亏损, 暂停交易至 ",
               TimeToString(g_cooldownUntil));
      }
   }
}

//+------------------------------------------------------------------+
//| 单笔持仓止损 + 追踪止损处理                                        |
//| 每个Tick检查所有本EA持仓, 按美元亏损直接平仓或更新追踪SL          |
//+------------------------------------------------------------------+
void ProcessPositionSLTrailing()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return;

   //--- 跨Tick追踪状态(用全局数组持久化, MQL5不支持局部static数组)
   //    g_trailTickets/g_trailBestPrices/g_trailActivated/g_trailPersistCount
   //    在全局作用域声明

   //--- 每次Tick重建可读状态表(仅用于诊断)
   g_trailCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionGetTicket(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ulong ticket = PositionGetTicket(i);
      double profit = PositionGetDouble(POSITION_PROFIT);
      int posType = (int)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice = (posType == POSITION_TYPE_BUY) ?
                        SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                        SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //============================================================
      // (A) 固定点数止损: 单笔亏损点数 >= InpSLPoints → 平仓
      //============================================================
      double slDollars = PointsToDollars(InpSLPoints, volume);
      if(InpUseStopLoss && profit <= -slDollars)
      {
         Print("🛑 止损 票据=", ticket, " 亏损=$", DoubleToString(profit, 2),
               " (上限-", InpSLPoints, "点=$", DoubleToString(slDollars, 2), ")");
         m_trade.PositionClose(ticket);
         MarkGroupTicketClosed(ticket);
         continue;
      }

      //============================================================
      // (B) 追踪止损
      //============================================================
      if(!InpUseTrailing) continue;

      double activateDollars = PointsToDollars(InpTrailActivatePoints, volume);
      // 查找是否已有追踪记录
      bool found = false;
      for(int t = 0; t < g_trailPersistCount; t++)
      {
         if(g_trailTickets[t] == ticket)
         {
            found = true;

            // 利润 >= 激活阈值 → 激活追踪
            if(!g_trailActivated[t] && profit >= activateDollars)
            {
               g_trailActivated[t] = true;
               g_trailBestPrices[t] = curPrice;
               Print("🔔 追踪激活 票据=", ticket, " 利润=$", DoubleToString(profit, 2),
                     " (", InpTrailActivatePoints, "点=$", DoubleToString(activateDollars, 2), ")");
            }

            if(g_trailActivated[t])
            {
               // 更新最优价格
               if(posType == POSITION_TYPE_BUY && curPrice > g_trailBestPrices[t])
                  g_trailBestPrices[t] = curPrice;
               else if(posType == POSITION_TYPE_SELL && curPrice < g_trailBestPrices[t])
                  g_trailBestPrices[t] = curPrice;

               // 追踪距离: 输入已是点数，直接换算为价格偏移
               // 1点 = tickSize， trailPts = 点数 * tickSize (价格单位)
               double trailPts = InpTrailDistancePoints * tickSize;
               if(trailPts <= 0) continue;
               double slPrice   = 0;
               double currSL    = PositionGetDouble(POSITION_SL);

               if(posType == POSITION_TYPE_BUY)
               {
                  slPrice = g_trailBestPrices[t] - trailPts * _Point;
                  if(slPrice < openPrice) slPrice = openPrice; // 不低于成本
                  if(currSL == 0 || slPrice > currSL)
                     m_trade.PositionModify(ticket, slPrice, 0);
               }
               else
               {
                  slPrice = g_trailBestPrices[t] + trailPts * _Point;
                  if(slPrice > openPrice) slPrice = openPrice;
                  if(currSL == 0 || slPrice < currSL)
                     m_trade.PositionModify(ticket, slPrice, 0);
               }
            }

            // 写入g_trails诊断
            if(g_trailCount < 10)
            {
               g_trails[g_trailCount].ticket    = ticket;
               g_trails[g_trailCount].direction = (posType == POSITION_TYPE_BUY) ? 1 : -1;
               g_trails[g_trailCount].activated = g_trailActivated[t];
               g_trails[g_trailCount].bestPrice = g_trailBestPrices[t];
               g_trailCount++;
            }
            break;
         }
      }

      if(!found && g_trailPersistCount < 10)
      {
         g_trailTickets[g_trailPersistCount]    = ticket;
         g_trailActivated[g_trailPersistCount]  = false;
         g_trailBestPrices[g_trailPersistCount] = curPrice;
         if(g_trailCount < 10)
         {
            g_trails[g_trailCount].ticket    = ticket;
            g_trails[g_trailCount].direction = (posType == POSITION_TYPE_BUY) ? 1 : -1;
            g_trails[g_trailCount].activated = false;
            g_trails[g_trailCount].bestPrice = curPrice;
            g_trailCount++;
         }
         g_trailPersistCount++;
      }
   }
}

//+------------------------------------------------------------------+
//| 标记组内某持仓已关闭(非组止盈主动关的)                            |
//+------------------------------------------------------------------+
void MarkGroupTicketClosed(ulong closedTicket)
{
   if(!g_group.active) return;
   for(int i = 0; i <= g_group.currentLevel; i++)
   {
      if(g_group.tickets[i] == closedTicket)
      {
         g_group.tickets[i] = 0;
         Print("  📌 组内 L", i, " 已平(止损/追踪), 组继续运行");
         g_lastCloseBarTime = iTime(_Symbol, _Period, 1); // 标记本Bar已平仓
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Tick事件 - 主逻辑                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1) 交易时间检查
   if(!IsTradingTime()) return;

   //--- 1b) 完成K线时间(用于每Bar一次入场锁定)
   datetime completedBarTime = iTime(_Symbol, _Period, 1);

   //--- 2) 每日权益更新
   UpdateDailyEquity();

   //--- 3) 每日亏损限制
   if(InpUseDailyLoss && CheckDailyLossReached()) return;

   //--- 4) 点差限制
   if(InpUseSpreadLimit)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpread) return;
   }

   //--- 5) 获取EMA值(最新完成K线)
   double ema[1];
   if(CopyBuffer(g_hEMA, 0, 1, 1, ema) < 1) return;
   double emaVal = ema[0];

   //--- 6) 吞没形态检测
   int signalDir = CheckEngulfingEntry(emaVal);

   //--- 7) 单笔止损 + 追踪止损处理(必须在入场逻辑之前, 先处理已有持仓)
   ProcessPositionSLTrailing();

   //--- 诊断日志(每10秒一次)
   static datetime lastLog = 0;
   if(TimeCurrent() - lastLog >= 10)
   {
      lastLog = TimeCurrent();
      double close1 = iClose(_Symbol, _Period, 1);
      string engulfInfo = "";
      if(IsBullishEngulfing(1)) engulfInfo = "多头吞没";
      else if(IsBearishEngulfing(1)) engulfInfo = "空头吞没";
      else engulfInfo = "无";

      Print(StringFormat("[诊断] Close:%.2f EMA:%.2f 方向:%s 吞没:%s 信号:%s 组层级:%d",
            close1, emaVal,
            close1 > emaVal ? "多" : (close1 < emaVal ? "空" : "平"),
            engulfInfo,
            signalDir == 1 ? "↑" : (signalDir == -1 ? "↓" : "无"),
            g_group.active ? g_group.currentLevel : -1));
   }

   //============================================================
   // 7) 组管理(止盈/止损/倍投) — 始终运行, 不受暂停影响
   //============================================================
   if(g_group.active)
   {
      if(!ValidateGroupPositions())
      {
         g_group.Reset();
         return;
      }

      //--- 7a) 检查同组总利润是否达标
      double totalProfit = GetGroupTotalProfit();
      double totalVolume = GetGroupTotalVolume();
      double tpDollars = PointsToDollars(InpTPPoints, totalVolume);
      if(totalProfit >= tpDollars)
      {
         Print("✅ 同组总利润 $", DoubleToString(totalProfit, 2), " (", InpTPPoints, "点=$", DoubleToString(tpDollars, 2), ") 全部平仓!");
         CloseAllGroupPositions();
         g_lastCloseBarTime = completedBarTime;
         OnGroupClosed(true);
         g_group.Reset();
         return;
      }

      //--- 7b) 阻断检查: 同Bar已平仓则不倍投
      bool barClosed = (completedBarTime == g_lastCloseBarTime);

      //--- 7c) 检查倍投
      if(!barClosed && g_group.currentLevel < InpMaxDoubles &&
         completedBarTime != g_lastDoubleBar)
      {
         int lastDir = g_group.dirs[g_group.currentLevel];
         int desiredDir = -lastDir;
         if(signalDir == desiredDir)
         {
            DoDoubleDown();
            g_lastDoubleBar = completedBarTime;
            return;
         }
      }
   }
   //============================================================
   // 8) 无活跃组 → 初始入场
   //============================================================
   else
   {
      // 阻断检查
      bool barClosed = (completedBarTime == g_lastCloseBarTime);
      bool inCooldown = (InpUseCooldown && TimeCurrent() < g_cooldownUntil);

      if(barClosed || inCooldown)
      {
         if(inCooldown)
         {
            if(TimeCurrent() - g_lastCooldownLog >= 60)
            {
               g_lastCooldownLog = TimeCurrent();
               int remain = (int)(g_cooldownUntil - TimeCurrent()) / 60;
               Print("⏳ 暂停中, 剩余约", remain, "分钟");
            }
         }
         return;
      }

      // 吞没形态入场, 每Bar最多1次
      if(signalDir != 0 && completedBarTime != g_lastEntryBar)
      {
         OpenInitialPosition(signalDir);
         g_lastEntryBar = completedBarTime;
      }
   } // 结束else(无活跃组)

} // 结束OnTick()

//+------------------------------------------------------------------+
//| 计算开仓手数                                                      |
//+------------------------------------------------------------------+
double CalcLot(int level)
{
   double baseLot;

   if(InpUseFixedLot)
   {
      baseLot = InpFixedLot;
   }
   else
   {
      double equity = m_account.Equity();
      baseLot = equity * InpRiskPercent / 10000.0;
      if(baseLot < InpMinLot) baseLot = InpMinLot;
   }

   // 倍投: level 0=1x, 1=2x, 2=4x, 3=8x
   double lot = baseLot * MathPow(2, level);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathRound(lot / step) * step;

   if(lot < InpMinLot) lot = InpMinLot;
   if(lot > InpMaxLot) lot = InpMaxLot;

   // 保证金检查
   double margin = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin))
   {
      double freeMargin = m_account.FreeMargin();
      if(margin > freeMargin * 0.8)
      {
         lot = MathFloor(freeMargin * 0.7 / margin * lot / step) * step;
         if(lot < InpMinLot) lot = InpMinLot;
      }
   }

   return(lot);
}

//+------------------------------------------------------------------+
//| 开初始仓                                                         |
//+------------------------------------------------------------------+
void OpenInitialPosition(int direction)
{
   double lot = CalcLot(0);
   double price = 0.0;
   int groupID = (int)TimeCurrent();

   if(direction == 1) // Buy
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(m_trade.Buy(lot, _Symbol, price, 0, 0,
                     StringFormat("EMA55_E_%d_0_B", groupID)))
      {
         ulong ticket = m_trade.ResultOrder();
         if(ticket > 0)
         {
            g_group.active = true;
            g_group.groupID = groupID;
            g_group.baseDir = 1;
            g_group.currentLevel = 0;
            g_group.tickets[0] = ticket;
            g_group.lots[0] = lot;
            g_group.dirs[0] = 1;
            Print("🟢 开多 L0 单: 手数=", lot, " 票据=", ticket);
         }
      }
   }
   else // Sell
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(m_trade.Sell(lot, _Symbol, price, 0, 0,
                      StringFormat("EMA55_E_%d_0_S", groupID)))
      {
         ulong ticket = m_trade.ResultOrder();
         if(ticket > 0)
         {
            g_group.active = true;
            g_group.groupID = groupID;
            g_group.baseDir = -1;
            g_group.currentLevel = 0;
            g_group.tickets[0] = ticket;
            g_group.lots[0] = lot;
            g_group.dirs[0] = -1;
            Print("🔴 开空 L0 单: 手数=", lot, " 票据=", ticket);
         }
      }
   }

   if(!g_group.active)
      Print("❌ 开仓失败: ", m_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| 倍投开仓                                                         |
//+------------------------------------------------------------------+
void DoDoubleDown()
{
   int nextLevel = g_group.currentLevel + 1;
   double lot = CalcLot(nextLevel);

   int lastDir = g_group.dirs[g_group.currentLevel];
   int newDir = -lastDir;

   double price;
   string cmt = StringFormat("EMA55_E_%d_%d_%s", g_group.groupID, nextLevel,
                              newDir == 1 ? "B" : "S");

   if(newDir == 1) // Buy
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(m_trade.Buy(lot, _Symbol, price, 0, 0, cmt))
      {
         ulong ticket = m_trade.ResultOrder();
         if(ticket > 0)
         {
            g_group.currentLevel = nextLevel;
            g_group.tickets[nextLevel] = ticket;
            g_group.lots[nextLevel] = lot;
            g_group.dirs[nextLevel] = 1;
            Print("🟢 倍投多 L", nextLevel, ": 手数=", lot, " 票据=", ticket);
         }
      }
   }
   else // Sell
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(m_trade.Sell(lot, _Symbol, price, 0, 0, cmt))
      {
         ulong ticket = m_trade.ResultOrder();
         if(ticket > 0)
         {
            g_group.currentLevel = nextLevel;
            g_group.tickets[nextLevel] = ticket;
            g_group.lots[nextLevel] = lot;
            g_group.dirs[nextLevel] = -1;
            Print("🔴 倍投空 L", nextLevel, ": 手数=", lot, " 票据=", ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 获取同组总利润                                                    |
//+------------------------------------------------------------------+
double GetGroupTotalProfit()
{
   double total = 0.0;
   for(int i = 0; i <= g_group.currentLevel; i++)
   {
      if(g_group.tickets[i] > 0 && PositionSelectByTicket(g_group.tickets[i]))
         total += PositionGetDouble(POSITION_PROFIT);
   }
   return(total);
}

//+------------------------------------------------------------------+
//| 平仓同组所有持仓                                                  |
//+------------------------------------------------------------------+
void CloseAllGroupPositions()
{
   for(int i = g_group.currentLevel; i >= 0; i--)
   {
      if(g_group.tickets[i] > 0 && PositionSelectByTicket(g_group.tickets[i]))
      {
         if(m_trade.PositionClose(g_group.tickets[i]))
            Print("  关闭 L", i);
         else
            Print("  ⚠️ 关闭 L", i, " 失败: ", m_trade.ResultRetcodeDescription());
         g_group.tickets[i] = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| 验证组内持仓是否仍然存活                                          |
//+------------------------------------------------------------------+
bool ValidateGroupPositions()
{
   int aliveCount = 0;
   for(int i = 0; i <= g_group.currentLevel; i++)
   {
      if(g_group.tickets[i] > 0)
      {
         if(!PositionSelectByTicket(g_group.tickets[i]))
         {
            Print("⚠️ L", i, " 票据=", g_group.tickets[i], " 持仓已不存在");
            g_group.tickets[i] = 0;
            continue;
         }
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         {
            Print("⚠️ L", i, " 魔法编号不匹配");
            g_group.tickets[i] = 0;
            continue;
         }
         aliveCount++;
      }
   }

   // 组内已无存活持仓 → 自动重置(算作亏损)
   if(aliveCount == 0 && g_group.active)
   {
      Print("📌 组内所有持仓已关闭, 自动重置组状态");
      g_lastCloseBarTime = iTime(_Symbol, _Period, 1);
      OnGroupClosed(false); // 亏损→递增连续亏损
      g_group.Reset();
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| 从现有持仓重建组状态                                              |
//+------------------------------------------------------------------+
void RebuildGroupFromPositions()
{
   g_group.Reset();

   int highestGroupID = -1;
   TempPos temp[4];
   int tempCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionGetTicket(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, "EMA55_E_") != 0) continue; // 格式: EMA55_E_{groupID}_{level}_{B/S}

      string parts[];
      int cnt = StringSplit(cmt, '_', parts);
      if(cnt < 5) continue;

      int groupID = (int)StringToInteger(parts[2]);
      int level   = (int)StringToInteger(parts[3]);
      int dir     = (parts[4] == "B") ? 1 : -1;

      if(groupID > highestGroupID) { highestGroupID = groupID; tempCount = 0; }
      if(groupID == highestGroupID && level >= 0 && level <= 3)
      {
         temp[tempCount].ticket = PositionGetTicket(i);
         temp[tempCount].level  = level;
         temp[tempCount].dir    = dir;
         temp[tempCount].lot    = PositionGetDouble(POSITION_VOLUME);
         tempCount++;
      }
   }

   if(tempCount == 0) return;

   g_group.active = true;
   g_group.groupID = highestGroupID;
   g_lastEntryBar  = iTime(_Symbol, _Period, 1);
   g_lastDoubleBar = iTime(_Symbol, _Period, 1);

   for(int i = 0; i < tempCount; i++)
   {
      int lvl = temp[i].level;
      g_group.tickets[lvl] = temp[i].ticket;
      g_group.lots[lvl]    = temp[i].lot;
      g_group.dirs[lvl]    = temp[i].dir;
      if(lvl > g_group.currentLevel) g_group.currentLevel = lvl;
   }
   g_group.baseDir = g_group.dirs[0];

   Print("🔄 已恢复组状态: GroupID=", g_group.groupID,
         " 首单=", (g_group.baseDir == 1 ? "多" : "空"),
         " 层级=", g_group.currentLevel);
}

//+------------------------------------------------------------------+
//| 交易时间检查(北京→服务器)                                        |
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
//| 更新日初权益                                                      |
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
//| 当日亏损是否达上限                                                |
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
         Print("🚫 当日亏损 ", DoubleToString(lossPct, 1), "% (上限",
               InpDailyLossPct, "%), 禁止开仓!");
         warned = true;
      }
      return(true);
   }
   if(lossPct < InpDailyLossPct * 0.8) warned = false;
   return(false);
}

//+------------------------------------------------------------------+
//| 打印组信息                                                        |
//+------------------------------------------------------------------+
void PrintGroupInfo()
{
   if(!g_group.active) { Print("当前无活跃交易组"); return; }

   string info = StringFormat("📊 组 #%d | 首单:%s | 层级:%d | 总利润:$%.2f",
         g_group.groupID,
         g_group.baseDir == 1 ? "多" : "空",
         g_group.currentLevel,
         GetGroupTotalProfit());

   for(int i = 0; i <= g_group.currentLevel; i++)
   {
      info += StringFormat("\n  L%d: 票据=%llu 手数=%.2f %s",
            i, g_group.tickets[i], g_group.lots[i],
            g_group.dirs[i] == 1 ? "多" : "空");
   }
   Print(info);
}

//+------------------------------------------------------------------+
//| Chart事件                                                         |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CLICK) PrintGroupInfo();
}
//+------------------------------------------------------------------+
