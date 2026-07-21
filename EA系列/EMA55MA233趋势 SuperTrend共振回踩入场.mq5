//+------------------------------------------------------------------+
//|                                        EMA55_SuperTrend_共振.mq5 |
//|                                          Senior Developer        |
//|                                                                  |
//|  策略: EMA55/MA233金叉死叉趋势 + M1 SuperTrend共振回踩入场        |
//|                                                                  |
//|  【趋势判断 - M1】                                                |
//|    EMA55上穿MA233 = 金叉 → 多头趋势(只做多)                       |
//|    EMA55下穿MA233 = 死叉 → 空头趋势(只做空)                         |
//|                                                                  |
//|  【入场 - M1】                                                    |
//|    多头共振: M1趋势多头 + M1 SuperTrend多头 + 价格回踩ST线±$0.5开多|
//|    空头共振: M1趋势空头 + M1 SuperTrend空头 + 价格回踩ST线±$0.5开空|
//|    不追高/不追空,只做共振后的回调入场                              |
//|                                                                  |
//|  【出场】                                                         |
//|    止损: 500点(5美金) | 止盈: 2500点(25美金)                     |
//|    追踪止损: 200点激活 → 700点保本                                |
//|                                                                  |
//|  【风控】                                                         |
//|    交易时间: 北京时间 07:30 ~ 次日03:30                           |
//|    当日最大亏损限制,点差限制                                       |
//+------------------------------------------------------------------+
#property copyright "Senior Developer"
#property version   "1.25"
#property description "M1 EMA55/MA233金叉死叉趋势 + M1 SuperTrend共振回踩入场"
#property description "M1:EMA55上穿MA233=金叉多头,下穿MA233=死叉空头"
#property description "SuperTrend与MA交叉趋势共振+回踩ST线$0.5内开仓"
#property description "止损500点/止盈2500点,追踪止损200点激活700点保本"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 输入参数                                                         |
//+------------------------------------------------------------------+
input group   "=== ★ 策略核心参数 ==="
input int     InpMagicNumber     = 20260515;        // 魔法编号
input double  InpStopLoss        = 500;             // 止损(点数)
input double  InpTakeProfit      = 2500;            // 止盈(点数)
input double  InpTouchDistance   = 0.50;            // ST线触碰距离(美元)

input group   "=== ★ 均线交叉趋势参数 ==="
input int     InpFastMAPeriod    = 55;              // 快线MA周期(EMA55)
input ENUM_MA_METHOD  InpFastMAMethod = MODE_EMA;   // 快线MA类型(EMA)
input int     InpSlowMAPeriod    = 233;             // 慢线MA周期(MA233)
input ENUM_MA_METHOD  InpSlowMAMethod = MODE_SMA;   // 慢线MA类型(SMA)
input ENUM_APPLIED_PRICE InpMAApplied = PRICE_CLOSE; // 均线应用价格

input group   "=== SuperTrend参数 ==="
input int     InpSTPeriod        = 10;              // SuperTrend ATR周期
input double  InpSTMultiplier    = 3.0;             // SuperTrend 倍数

input group   "=== ★ 交易时间(北京时间) ==="
input string  InpStartTime       = "07:30";         // 开始时间(北京)
input string  InpEndTime         = "03:30";         // 结束时间(北京,次日凌晨)

input group   "=== ★ 仓位管理 ==="
input bool    InpUseFixedLot     = true;            // true=固定手数 false=百分比
input double  InpFixedLot        = 0.01;            // 固定手数
input double  InpRiskPercent     = 1.0;             // 风险百分比(%)
input double  InpMinLot          = 0.01;            // 最小手数
input double  InpMaxLot          = 1.0;             // 最大手数

input group   "=== ★ 风控管理 ==="
input bool    InpUseDailyLoss    = true;            // 启用当日最大亏损限制
input double  InpDailyLossPct    = 5.0;             // 当日最大亏损(%)
input bool    InpUseSpreadLimit  = true;            // 启用点差限制
input int     InpMaxSpread       = 50;              // 最大允许点差

input group   "=== ★ 追踪方式A: 渐进式(持续追踪SL,与B互斥) ==="
input bool    InpUseTrailA        = false;           // 启用追踪A(渐进式,与B互斥)
input int     InpTrailAActivate   = 20;              // A: 追踪激活利润点数(≥此值开始追踪)
input int     InpTrailABreakeven  = 320;             // A: 保本点数(SL移入场价±2点)

input group   "=== ★ 追踪方式B: 一次性保本(与A互斥) ==="
input bool    InpUseTrailB        = true;            // 启用追踪B(一次性保本,与A互斥)
input int     InpTrailBTrigger    = 320;             // B: 触发保本的利润点数
input int     InpTrailBProtect    = 20;              // B: 保护利润(SL移入场价±此点数)

input group   "=== ★ 入场重试控制 ==="
input int     InpReEntryCooldown  = 3;               // 平仓后冷却M1 K线数(防同一信号反复入场)

//+------------------------------------------------------------------+
//| 全局变量                                                         |
//+------------------------------------------------------------------+
CTrade      m_trade;
int         g_hFastMA  = INVALID_HANDLE;  // M1 EMA55指标句柄(快线)
int         g_hSlowMA  = INVALID_HANDLE;  // M1 MA233指标句柄(慢线)
int         g_hATR     = INVALID_HANDLE;  // M1 ATR指标句柄(用于SuperTrend)

//--- 趋势方向: 1=多头(金叉状态), -1=空头(死叉状态), 0=未知
int         g_trendDir      = 0;
int         g_trendInitBars = 0;          // 趋势初始化所需K线计数
datetime    g_lastTrendBar  = 0;          // 上次处理趋势的M1K线时间

datetime    g_lastM1Bar  = 0;             // 上次处理的M1K线时间
int         g_bjOffset   = 0;             // 北京时间偏移(秒)
bool        g_firstRun   = true;          // 首次运行标记

//--- M1 SuperTrend状态
bool        g_stUp       = true;          // true=多头 false=空头
double      g_stValue    = 0.0;           // SuperTrend线当前价格
int         g_stReady    = 0;             // SuperTrend就绪状态(需2根K线预热)

//--- 风控状态
double      g_dayBal     = 0.0;           // 当日初始余额
int         g_dayNum     = -1;            // 当前日序号
bool        g_dayLimit   = false;         // 当日是否已达亏损限制
bool        g_entryBlock = false;         // 已入场标记(同一根M1K线不再重复入场)
datetime    g_entryBarTime = 0;           // 入场时的K线时间
datetime    g_cooldownBarTime = 0;        // 平仓冷却起始K线时间(0=无需冷却)

//--- 缓存数据
double      g_pt         = 0.0;           // 点值
int         g_dig        = 0;             // 小数位数

//--- 追踪止损状态(A/B模式共用)
bool        g_trailBLocked  = false;        // B模式锁定标记(SL触发后不再修改)
ulong       g_trailTicket   = 0;            // 当前追踪的持仓ticket
int         g_trailFailCnt  = 0;            // 连续失败次数

//--- 定时器
int         g_timerId    = -1;            // 定时器ID

//+------------------------------------------------------------------+
//| 初始化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 交易设置
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(50);
   m_trade.SetAsyncMode(false);           // 同步模式,确保下单结果即时可知

   //--- 缓存常用数据
   g_pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- 参数校验
   if(InpStopLoss <= 0)
   {
      Print("❌ 止损必须大于0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTakeProfit <= 0)
   {
      Print("❌ 止盈必须大于0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTouchDistance <= 0)
   {
      Print("❌ ST线触碰距离必须大于0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpFixedLot <= 0 && InpUseFixedLot)
   {
      Print("❌ 固定手数必须大于0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpFastMAPeriod < 2)
   {
      Print("❌ 快线MA周期必须>=2");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSlowMAPeriod < 2)
   {
      Print("❌ 慢线MA周期必须>=2");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- 追踪模式互斥检查: A与B同时启用时A优先
   if(InpUseTrailA && InpUseTrailB)
   {
      Print("⚠️ 追踪A和B同时启用,按A优先处理(渐进式)");
   }

   //--- 创建M1均线指标(用于金叉死叉趋势判断)
   g_hFastMA = iMA(_Symbol, PERIOD_M1, InpFastMAPeriod, 0, InpFastMAMethod, InpMAApplied);
   g_hSlowMA = iMA(_Symbol, PERIOD_M1, InpSlowMAPeriod, 0, InpSlowMAMethod, InpMAApplied);
   g_hATR    = iATR(_Symbol, PERIOD_M1, InpSTPeriod);
   if(g_hFastMA == INVALID_HANDLE || g_hSlowMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      Print("❌ 创建指标失败,请检查是否连接到行情");
      Print("   FastMA=", g_hFastMA, " SlowMA=", g_hSlowMA, " ATR=", g_hATR);
      return INIT_FAILED;
   }

   //--- 计算北京时间偏移
   //    BeijingTime = ServerTime + g_bjOffset
   int srvGmtOffset = (int)(TimeCurrent() - TimeGMT());
   g_bjOffset = 8 * 3600 - srvGmtOffset;
   if(MathAbs(g_bjOffset - 5*3600) > 1800)
   {
      Print("ℹ️ 服务器与北京时间偏差=", g_bjOffset/3600, "小时,请核实交易时间设置");
   }

   //--- 初始化K线时间
   g_lastM1Bar = iTime(_Symbol, PERIOD_M1, 0);
   g_lastTrendBar = iTime(_Symbol, PERIOD_M1, 0);

   //--- 初始化风控
   ResetDay();

   //--- 创建定时器(每2秒处理一次,保障无Tick时也能运行追踪止损)
   g_timerId = EventSetMillisecondTimer(2000);
   if(g_timerId < 0)
   {
      Print("⚠️ 定时器创建失败,将仅依赖OnTick运行");
   }

   //--- 打印启动信息
   Print("╔══════════════════════════════════════════════╗");
   Print("║  EMA55/MA233金叉死叉 + SuperTrend 共振EA v1.20 ║");
   Print("╠══════════════════════════════════════════════╣");
   Print("║ 服务器时间: ", TimeToString(TimeCurrent()));
   Print("║ 北京时间:   ", TimeToString(TimeCurrent() + g_bjOffset));
   Print("║ 交易品种:   ", _Symbol);
   Print("║ 快线:       EMA", InpFastMAPeriod, "(", EnumToString(InpFastMAMethod), ")");
   Print("║ 慢线:       MA", InpSlowMAPeriod, "(", EnumToString(InpSlowMAMethod), ")");
   Print("║ ST周期/倍数: ", InpSTPeriod, "/", InpSTMultiplier);
   Print("║ 止损:       ", InpStopLoss, "点 (", InpStopLoss*10, "美分)");
   Print("║ 止盈:       ", InpTakeProfit, "点 (", InpTakeProfit*10, "美分)");
   Print("║ 触碰距离:   ", InpTouchDistance, " USD");
   Print("║ 追踪模式:   ", InpUseTrailA ? "A-渐进式" : InpUseTrailB ? "B-一次性保本" : "关闭");
   Print("╚══════════════════════════════════════════════╝");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 反初始化                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_timerId >= 0)
      EventKillTimer();

   if(g_hFastMA != INVALID_HANDLE) { IndicatorRelease(g_hFastMA); g_hFastMA = INVALID_HANDLE; }
   if(g_hSlowMA != INVALID_HANDLE) { IndicatorRelease(g_hSlowMA); g_hSlowMA = INVALID_HANDLE; }
   if(g_hATR   != INVALID_HANDLE) { IndicatorRelease(g_hATR);   g_hATR   = INVALID_HANDLE; }

   Print("📌 EA已停止,原因代码: ", reason);
}

//+------------------------------------------------------------------+
//| 定时器处理(保障持续运行)                                          |
//|  每2秒触发一次,即使没有新Tick也能更新追踪止损                      |
//+------------------------------------------------------------------+
void OnTimer()
{
   //--- 每日状态更新
   UpdateDay();
   if(g_dayLimit)
   {
      CheckTrail();   // 已达亏损上限,仅追踪止损
      return;
   }

   //--- 已有持仓追踪止损(保障无Tick时也能移动止损)
   CheckTrail();

   //--- 交易时间外不处理新开仓
   if(!IsTradeTime()) return;
   if(!CheckDayLoss()) return;

   //--- 平仓冷却管理(无持仓时启动冷却计时)
   UpdateCooldown();

   //--- 已有持仓则不开新仓
   if(HasMyPos()) return;

   //--- 点差检查
   if(!CheckSpread()) return;

   //--- 更新趋势方向(EMA55/MA233金叉死叉)
   UpdateTrendDirection();

   //--- 检查入场条件
   CheckEntry();
}

//+------------------------------------------------------------------+
//| 主Tick处理                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 每日状态更新
   UpdateDay();
   if(g_dayLimit)
   {
      CheckTrail();
      return;
   }

   //--- 已有持仓追踪止损(在时间/亏损检查之前,确保非交易时间也能移动SL)
   CheckTrail();

   //--- 交易时间检查
   if(!IsTradeTime()) return;

   //--- 当日亏损检查
   if(!CheckDayLoss()) return;

   //--- 平仓冷却管理(无持仓时启动冷却计时)
   UpdateCooldown();

   //--- 检查是否已有持仓(一次只交易一单)
   if(HasMyPos()) return;

   //--- 点差检查
   if(!CheckSpread()) return;

   //--- 更新趋势方向(EMA55/MA233金叉死叉)
   UpdateTrendDirection();

   //--- 检查入场条件
   CheckEntry();
}

//+------------------------------------------------------------------+
//| 交易时间检查(北京时间)                                             |
//|  默认: 07:30 ~ 03:30(次日凌晨)                                    |
//|  服务器时间比北京时间晚5小时,即: 02:30 ~ 22:30(服务器时间)        |
//+------------------------------------------------------------------+
bool IsTradeTime()
{
   datetime bjTime = TimeCurrent() + g_bjOffset;
   MqlDateTime dt;
   if(!TimeToStruct(bjTime, dt))
   {
      Print("⚠️ IsTradeTime: TimeToStruct转换失败");
      return false;
   }

   int curMin = dt.hour * 60 + dt.min;

   //--- 解析开始时间(格式 HH:MM)
   int sHour = 7, sMin = 30;
   if(StringLen(InpStartTime) >= 5)
   {
      string parts[2];
      int split = StringSplit(InpStartTime, ':', parts);
      if(split == 2)
      {
         sHour = MathMax(0, MathMin(23, (int)StringToInteger(parts[0])));
         sMin  = MathMax(0, MathMin(59, (int)StringToInteger(parts[1])));
      }
      else
      {
         Print("⚠️ 开始时间格式异常: ", InpStartTime, ",使用默认07:30");
      }
   }

   //--- 解析结束时间
   int eHour = 3, eMin = 30;
   if(StringLen(InpEndTime) >= 5)
   {
      string parts[2];
      int split = StringSplit(InpEndTime, ':', parts);
      if(split == 2)
      {
         eHour = MathMax(0, MathMin(23, (int)StringToInteger(parts[0])));
         eMin  = MathMax(0, MathMin(59, (int)StringToInteger(parts[1])));
      }
      else
      {
         Print("⚠️ 结束时间格式异常: ", InpEndTime, ",使用默认03:30");
      }
   }

   int startMin = sHour * 60 + sMin;
   int endMin   = eHour * 60 + eMin;

   //--- 处理跨天情况(结束时间小于开始时间,表示次日凌晨)
   if(startMin <= endMin)
   {
      // 同一天内
      return (curMin >= startMin && curMin <= endMin);
   }
   else
   {
      // 跨天: 07:30 ~ 次日03:30
      return (curMin >= startMin || curMin <= endMin);
   }
}

//+------------------------------------------------------------------+
//| 每日更新                                                         |
//+------------------------------------------------------------------+
void UpdateDay()
{
   datetime bjTime = TimeCurrent() + g_bjOffset;
   MqlDateTime dt;
   if(!TimeToStruct(bjTime, dt))
      return;

   int today = dt.day_of_year;
   if(today != g_dayNum)
   {
      if(!g_firstRun)
      {
         double bal = AccountInfoDouble(ACCOUNT_BALANCE);
         double chg = bal - g_dayBal;
         Print("┌───────────────────────────────────────┐");
         Print("│ 新交易日 昨日账户变化: ", 
               (chg >= 0 ? "+" : ""), DoubleToString(chg, 2),
               " (", (chg >= 0 ? "+" : ""), 
               (g_dayBal > 0 ? DoubleToString(chg / g_dayBal * 100, 1) : "0"), "%) │");
         Print("└───────────────────────────────────────┘");
      }
      ResetDay();
      g_firstRun = false;
   }
}

//+------------------------------------------------------------------+
//| 重置每日风控状态                                                   |
//+------------------------------------------------------------------+
void ResetDay()
{
   datetime bjTime = TimeCurrent() + g_bjOffset;
   MqlDateTime dt;
   if(!TimeToStruct(bjTime, dt))
      return;

   g_dayNum   = dt.day_of_year;
   g_dayBal   = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayLimit = false;
   g_trailFailCnt = 0;
   g_trailBLocked = false;
   g_trailTicket  = 0;
   g_cooldownBarTime = 0;

   Print("📅 新交易日初始化 余额=", DoubleToString(g_dayBal, 2));
}

//+------------------------------------------------------------------+
//| 当日最大亏损检查                                                   |
//+------------------------------------------------------------------+
bool CheckDayLoss()
{
   if(g_dayLimit) return false;
   if(!InpUseDailyLoss) return true;

   double curBal = AccountInfoDouble(ACCOUNT_BALANCE);

   //--- 如果当前余额 > 日初余额,说明有盈利,重置日初余额
   if(curBal > g_dayBal)
   {
      g_dayBal = curBal;
      return true;
   }

   double loss   = g_dayBal - curBal;

   if(g_dayBal > 0)
   {
      double lossPct = loss / g_dayBal * 100.0;
      if(lossPct >= InpDailyLossPct)
      {
         g_dayLimit = true;
         Print("⚠️ 风控触发: 当日亏损已达 ", DoubleToString(lossPct, 1),
               "%, 超过 ", DoubleToString(InpDailyLossPct, 1), "% 限制");
         Print("   今日禁止开新仓,仅执行追踪止损");
         return false;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| 点差检查                                                         |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   if(!InpUseSpreadLimit) return true;

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
   {
      static int lastLogMin = 0;
      int curMin = (int)(TimeCurrent() / 60);
      if(curMin != lastLogMin)
      {
         lastLogMin = curMin;
         Print("点差过大: ", spread, " (限制: ", InpMaxSpread, ")");
      }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 检查是否有持仓(仅限本EA)                                          |
//+------------------------------------------------------------------+
bool HasMyPos()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| 获取当前持仓ticket(仅限本EA)                                      |
//+------------------------------------------------------------------+
ulong GetMyPosTicket()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         return ticket;
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| 更新趋势方向(基于EMA55与MA233金叉/死叉)                            |
//|  g_trendDir = 1  → 多头(金叉状态,只做多)                          |
//|  g_trendDir = -1 → 空头(死叉状态,只做空)                          |
//|  每根M1新K线时更新                                                 |
//+------------------------------------------------------------------+
void UpdateTrendDirection()
{
   //--- 每根M1新K线时更新趋势
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == 0) return;
   if(curBar == g_lastTrendBar) return; // 同一根K线不重复处理
   g_lastTrendBar = curBar;

   //--- 准备缓冲区
   double fast[3], slow[3];

   //--- 取已完成K线(idx=1,2,3)的三根数据做交叉检测
   //    fast[0]=最新完成K线, fast[1]=前一根, fast[2]=前两根
   if(CopyBuffer(g_hFastMA, 0, 1, 3, fast) < 3) return;
   if(CopyBuffer(g_hSlowMA, 0, 1, 3, slow) < 3) return;

   //--- 数据有效性检查
   if(fast[0] <= 0 || slow[0] <= 0) return;

   //--- 趋势初始化(首次运行): 用当前快慢线位置确定初始方向
   if(g_trendInitBars < 2)
   {
      g_trendInitBars++;
      if(g_trendInitBars == 1)
      {
         g_trendDir = (fast[0] > slow[0]) ? 1 : -1;
         Print("🔧 趋势初始化: EMA", InpFastMAPeriod, "=", DoubleToString(fast[0], g_dig),
               " MA", InpSlowMAPeriod, "=", DoubleToString(slow[0], g_dig),
               " → ", (g_trendDir == 1 ? "多头(金叉)" : "空头(死叉)"));
      }
      else // g_trendInitBars == 2, 用第二根K线校准
      {
         int newDir = (fast[0] > slow[0]) ? 1 : -1;
         if(newDir != g_trendDir)
         {
            Print("🔧 趋势校正: ", (g_trendDir == 1 ? "多头→空头" : "空头→多头"),
                  " (第二根K线确认)");
            g_trendDir = newDir;
         }
         Print("🔧 趋势预热完成: ",
               (g_trendDir == 1 ? "多头(金叉)" : "空头(死叉)"));
      }
      return;
   }

   //--- 记录旧方向
   int oldDir = g_trendDir;

   //====================================================
   // 1) 金叉精确检测: 本bar快线>慢线 且 前bar快线≤慢线
   //====================================================
   if(fast[0] > slow[0] && fast[1] <= slow[1])
   {
      g_trendDir = 1;
      if(g_trendDir != oldDir)
      {
         Print("🔵 金叉! EMA", InpFastMAPeriod, "=", DoubleToString(fast[0], g_dig),
               " MA", InpSlowMAPeriod, "=", DoubleToString(slow[0], g_dig),
               " → 多头趋势(只做多)");
      }
   }
   //====================================================
   // 2) 死叉精确检测: 本bar快线<慢线 且 前bar快线≥慢线
   //====================================================
   else if(fast[0] < slow[0] && fast[1] >= slow[1])
   {
      g_trendDir = -1;
      if(g_trendDir != oldDir)
      {
         Print("🔴 死叉! EMA", InpFastMAPeriod, "=", DoubleToString(fast[0], g_dig),
               " MA", InpSlowMAPeriod, "=", DoubleToString(slow[0], g_dig),
               " → 空头趋势(只做空)");
      }
   }
   //====================================================
   // 3) 未交叉时: 确保方向与快慢线当前位置一致
   //====================================================
   else
   {
      if(g_trendDir == 1 && fast[0] < slow[0])
      {
         g_trendDir = -1;
         Print("⚠️ 位置修正: 多头→空头(快线已落回慢线下方)");
      }
      else if(g_trendDir == -1 && fast[0] > slow[0])
      {
         g_trendDir = 1;
         Print("⚠️ 位置修正: 空头→多头(快线已升回慢线上方)");
      }
   }
}

//+------------------------------------------------------------------+
//| M1 SuperTrend计算                                                 |
//|  使用ATR计算超级趋势指标                                           |
//|  每根新M1 K线时更新(用已完成K线数据)                                |
//+------------------------------------------------------------------+
void UpdateST()
{
   double atrBuf[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, atrBuf) < 1) return;

   double atrVal = atrBuf[0];
   if(atrVal <= 0)
   {
      return;
   }

   //--- 使用已完成K线(bar[1])的数据
   double hi   = iHigh(_Symbol, PERIOD_M1, 1);
   double lo   = iLow(_Symbol, PERIOD_M1, 1);
   double cl   = iClose(_Symbol, PERIOD_M1, 1);
   if(hi <= 0 || lo <= 0 || cl <= 0)
   {
      return;
   }

   double hl2  = (hi + lo) / 2.0;
   double upBand = hl2 + InpSTMultiplier * atrVal;
   double dnBand = hl2 - InpSTMultiplier * atrVal;

   //--- 预热阶段(需要2根K线初始化,每根都更新方向)
   if(g_stReady < 2)
   {
      g_stReady++;
      if(g_stReady == 1)
      {
         g_stUp = (cl > dnBand);
         g_stValue = g_stUp ? dnBand : upBand;
      }
      else // g_stReady == 2
      {
         double prevVal = g_stValue;
         if(cl > prevVal)
         {
            g_stUp = true;
            g_stValue = (dnBand > prevVal) ? dnBand : prevVal;
         }
         else
         {
            g_stUp = false;
            g_stValue = (upBand < prevVal) ? upBand : prevVal;
         }
      }
      return;
   }

   //--- 记录旧值用于日志
   bool oldUp = g_stUp;
   double oldVal = g_stValue;

   //--- 标准SuperTrend算法
   if(g_stUp)
   {
      // 当前多头: 收盘 > ST线 → 维持多头,否则翻空
      if(cl > g_stValue)
      {
         g_stUp = true;
         g_stValue = (dnBand > oldVal) ? dnBand : oldVal;
      }
      else
      {
         g_stUp = false;
         g_stValue = upBand;
      }
   }
   else
   {
      // 当前空头: 收盘 < ST线 → 维持空头,否则翻多
      if(cl < g_stValue)
      {
         g_stUp = false;
         g_stValue = (upBand < oldVal) ? upBand : oldVal;
      }
      else
      {
         g_stUp = true;
         g_stValue = dnBand;
      }
   }

   //--- 预热完成时打印初始状态
   if(g_stReady == 2)
   {
      Print("🔧 SuperTrend预热完成: ",
            (g_stUp ? "多头" : "空头"),
            " ST线=", DoubleToString(g_stValue, g_dig));
   }

   //--- 方向变化时打印
   if(g_stUp != oldUp)
   {
      Print("🔄 M1 SuperTrend: ",
            (oldUp ? "多头→空头" : "空头→多头"),
            " 价格=", DoubleToString(cl, g_dig),
            " ST=", DoubleToString(g_stValue, g_dig));
   }
}

//+------------------------------------------------------------------+
//| 平仓冷却管理                                                      |
//|  持仓中 → 重置冷却                                                |
//|  平仓后 → 记录起始K线时间,经过InpReEntryCooldown根K线后恢复入场    |
//+------------------------------------------------------------------+
void UpdateCooldown()
{
   bool hasPos = HasMyPos();

   // 有持仓 → 重置冷却(等平仓后再从0开始计时)
   if(hasPos)
   {
      if(g_cooldownBarTime != 0)
         g_cooldownBarTime = 0;
      return;
   }

   // 无持仓且入场被锁但冷却未开始 → 启动冷却
   if(g_entryBlock && g_cooldownBarTime == 0)
   {
      g_cooldownBarTime = iTime(_Symbol, PERIOD_M1, 0);
      Print("⏳ 平仓冷却开始: 等待 ", InpReEntryCooldown, " 根M1 K线后恢复入场检测");
   }
}

//+------------------------------------------------------------------+
//| 入场条件检查                                                      |
//|                                                                  |
//|  核心逻辑:                                                        |
//|  1. MA交叉趋势与M1 SuperTrend方向一致(共振)                       |
//|  2. 价格回踩到SuperTrend线附近(±$0.5)                             |
//|  3. 不追高/不追空,只在回调时入场                                  |
//|                                                                  |
//|  多头入场: 金叉多头 + ST多头 + 价格回踩ST线                       |
//|  空头入场: 死叉空头 + ST空头 + 价格回踩ST线                       |
//+------------------------------------------------------------------+
void CheckEntry()
{
   //--- M1新K线时更新SuperTrend & 冷却检查
   datetime curM1Bar = iTime(_Symbol, PERIOD_M1, 0);
   if(curM1Bar == 0) return;
   if(curM1Bar != g_lastM1Bar)
   {
      g_lastM1Bar = curM1Bar;
      bool prevStUp = g_stUp;       // 记录旧ST方向
      UpdateST();
      // ST方向翻转 → 重置入场标记(新信号)
      if(g_stReady >= 2 && g_stUp != prevStUp)
         g_entryBlock = false;
      
      // 平仓冷却到期 → 恢复入场
      if(g_entryBlock && g_cooldownBarTime > 0)
      {
         int barsPassed = (int)((curM1Bar - g_cooldownBarTime) / 60);
         if(barsPassed >= InpReEntryCooldown)
         {
            g_entryBlock = false;
            g_cooldownBarTime = 0;
            Print("✅ 平仓冷却到期(", InpReEntryCooldown, "根K线),恢复入场检测");
         }
      }
   }

   //--- SuperTrend未就绪或趋势未确立
   if(g_stReady < 2) return;
   if(g_trendDir == 0) return;

   //--- 同一根M1K线只入场一次
   if(g_entryBlock) return;

   //--- 检查共振: ST方向必须与MA交叉趋势一致
   bool isBullAligned = (g_trendDir == 1 && g_stUp);
   bool isBearAligned = (g_trendDir == -1 && !g_stUp);

   if(!isBullAligned && !isBearAligned)
   {
      //--- 诊断日志: 每5分钟打印一次当前状态
      static datetime s_lastDiagLog = 0;
      if(s_lastDiagLog != curM1Bar && (curM1Bar % 300) == 0)
      {
         s_lastDiagLog = curM1Bar;
         string trendStr = (g_trendDir == 1 ? "多头(金叉)" :
                           g_trendDir == -1 ? "空头(死叉)" : "无趋势");
         string stStr = g_stUp ? "多头(↑)" : "空头(↓)";
         Print("📋 诊断: MA趋势=", trendStr, " ST=", stStr,
               " ST线=", DoubleToString(g_stValue, g_dig),
               " 共振=", (isBullAligned ? "多✓" : isBearAligned ? "空✓" : "无✗"));
      }
      return;
   }

   //--- 可用保证金检查
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0)
   {
      Print("⚠️ 可用保证金不足: ", DoubleToString(freeMargin, 2));
      return;
   }

   //============================================================
   // 多头入场: 价格回踩到SuperTrend线附近
   //============================================================
   if(isBullAligned)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double dist = ask - g_stValue;

      if(dist >= 0 && dist <= InpTouchDistance)
      {
         double lot = CalcLot();
         if(lot <= 0) return;

         g_entryBlock = true;
         g_entryBarTime = curM1Bar;

         Print("🔵 多头共振+回踩到位! 触发开多");
         Print("   MA趋势=金叉多头  ST趋势=多头(↑) ST线=", DoubleToString(g_stValue, g_dig));
         Print("   当前Ask=", DoubleToString(ask, g_dig),
               " 距离ST线=", DoubleToString(dist, g_dig), " USD");
         OpenBuy(lot);
      }
   }

   //============================================================
   // 空头入场: 价格回踩到SuperTrend线附近
   //============================================================
   if(isBearAligned)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double dist = g_stValue - bid;

      if(dist >= 0 && dist <= InpTouchDistance)
      {
         double lot = CalcLot();
         if(lot <= 0) return;

         g_entryBlock = true;
         g_entryBarTime = curM1Bar;

         Print("🔴 空头共振+回踩到位! 触发开空");
         Print("   MA趋势=死叉空头  ST趋势=空头(↓) ST线=", DoubleToString(g_stValue, g_dig));
         Print("   当前Bid=", DoubleToString(bid, g_dig),
               " 距离ST线=", DoubleToString(dist, g_dig), " USD");
         OpenSell(lot);
      }
   }
}

//+------------------------------------------------------------------+
//| 开多单                                                           |
//+------------------------------------------------------------------+
void OpenBuy(double lot)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = NormalizeDouble(ask - InpStopLoss * g_pt, g_dig);
   double tp  = NormalizeDouble(ask + InpTakeProfit * g_pt, g_dig);

   FixSLTP(ask, true, sl, tp);

   if(sl >= ask)
   {
      Print("❌ 多单SL无效(sl>=ask),请检查止损点数设置: sl=", sl, " ask=", ask);
      g_entryBlock = false;
      return;
   }
   if(tp <= ask)
   {
      Print("❌ 多单TP无效(tp<=ask),请检查止盈点数设置");
      g_entryBlock = false;
      return;
   }

   if(m_trade.Buy(lot, _Symbol, ask, sl, tp, "ST-Buy"))
   {
      Print("✅ 多单开仓成功  Lot=", DoubleToString(lot, 2),
            " 入场=", DoubleToString(ask, g_dig),
            " SL=", DoubleToString(sl, g_dig),
            " TP=", DoubleToString(tp, g_dig));
      g_trailBLocked = false;   // 新仓位,重置B模式锁定
      g_trailTicket  = 0;       // 重置追踪状态
      g_trailFailCnt = 0;
   }
   else
   {
      Print("❌ 多单开仓失败: ", m_trade.ResultRetcodeDescription());
      g_entryBlock = false;
   }
}

//+------------------------------------------------------------------+
//| 开空单                                                           |
//+------------------------------------------------------------------+
void OpenSell(double lot)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = NormalizeDouble(bid + InpStopLoss * g_pt, g_dig);
   double tp  = NormalizeDouble(bid - InpTakeProfit * g_pt, g_dig);

   FixSLTP(bid, false, sl, tp);

   if(sl <= bid)
   {
      Print("❌ 空单SL无效(sl<=bid),请检查止损点数设置");
      g_entryBlock = false;
      return;
   }
   if(tp >= bid)
   {
      Print("❌ 空单TP无效(tp>=bid),请检查止盈点数设置");
      g_entryBlock = false;
      return;
   }

   if(m_trade.Sell(lot, _Symbol, bid, sl, tp, "ST-Sell"))
   {
      Print("✅ 空单开仓成功  Lot=", DoubleToString(lot, 2),
            " 入场=", DoubleToString(bid, g_dig),
            " SL=", DoubleToString(sl, g_dig),
            " TP=", DoubleToString(tp, g_dig));
      g_trailBLocked = false;   // 新仓位,重置B模式锁定
      g_trailTicket  = 0;       // 重置追踪状态
      g_trailFailCnt = 0;
   }
   else
   {
      Print("❌ 空单开仓失败: ", m_trade.ResultRetcodeDescription());
      g_entryBlock = false;
   }
}

//+------------------------------------------------------------------+
//| 修正SL/TP以满足交易所最小止损距离要求                             |
//+------------------------------------------------------------------+
void FixSLTP(double entryPrice, bool isBuy, double &sl, double &tp)
{
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_pt;
   if(stopLevel <= 0) return;

   if(isBuy)
   {
      if((entryPrice - sl) < stopLevel)
         sl = NormalizeDouble(entryPrice - stopLevel, g_dig);
      if((tp - entryPrice) < stopLevel)
         tp = NormalizeDouble(entryPrice + stopLevel, g_dig);
   }
   else
   {
      if((sl - entryPrice) < stopLevel)
         sl = NormalizeDouble(entryPrice + stopLevel, g_dig);
      if((entryPrice - tp) < stopLevel)
         tp = NormalizeDouble(entryPrice - stopLevel, g_dig);
   }

   double maxStopDistance = entryPrice + 10000 * g_pt;
   double minStopDistance = entryPrice - 10000 * g_pt;
   sl = MathMax(MathMin(sl, maxStopDistance), minStopDistance);
   tp = MathMax(MathMin(tp, maxStopDistance), minStopDistance);
}

//+------------------------------------------------------------------+
//| 计算手数                                                         |
//|  支持固定手数和百分比风险模式                                      |
//+------------------------------------------------------------------+
double CalcLot()
{
   double lot;

   if(InpUseFixedLot)
   {
      lot = InpFixedLot;
   }
   else
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance <= 0)
      {
         Print("⚠️ 账户余额异常(", DoubleToString(balance, 2), "),使用固定手数: ", InpFixedLot);
         return InpFixedLot;
      }

      double riskMoney = balance * InpRiskPercent / 100.0;

      double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickValue <= 0 || tickSize <= 0 || g_pt <= 0)
      {
         Print("⚠️ 无法计算点值,使用固定手数: ", InpFixedLot);
         return InpFixedLot;
      }

      double pointValue = tickValue / tickSize * g_pt;
      if(pointValue <= 0)
      {
         Print("⚠️ 点值计算异常,使用固定手数: ", InpFixedLot);
         return InpFixedLot;
      }

      double lossPerLot = InpStopLoss * pointValue;
      if(lossPerLot <= 0)
      {
         Print("⚠️ 每手亏损计算异常,使用固定手数: ", InpFixedLot);
         return InpFixedLot;
      }

      lot = riskMoney / lossPerLot;
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0)
      lot = MathFloor(lot / step) * step;

   double exchMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double exchMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(exchMin <= 0) exchMin = InpMinLot;
   if(exchMax <= 0) exchMax = InpMaxLot;

   double finalMin = MathMax(InpMinLot, exchMin);
   double finalMax = MathMin(InpMaxLot, exchMax);

   lot = MathMax(lot, finalMin);
   lot = MathMin(lot, finalMax);

   if(!InpUseFixedLot && lot > 0)
   {
      double marginFree = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double marginReq  = 0;
      if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq))
      {
         if(marginReq >= marginFree)
         {
            Print("⚠️ 手数过大(", DoubleToString(lot, 2), "),所需保证金=",
                  DoubleToString(marginReq, 2), " > 可用=", DoubleToString(marginFree, 2));
            double safeLot = marginFree * 0.9 / (marginReq / lot);
            safeLot = MathFloor(safeLot / step) * step;
            lot = MathMax(safeLot, finalMin);
            lot = MathMin(lot, finalMax);
            if(lot <= 0)
            {
               Print("⚠️ 调整后手数仍为0,使用最小手数: ", finalMin);
               lot = finalMin;
            }
         }
      }
   }

   return lot;
}

//+------------------------------------------------------------------+
//| 追踪止损(支持A/B双模式)                                           |
//|                                                                  |
//|  模式A(渐进式):                                                    |
//|    Phase 1: 利润≥InpTrailABreakeven → SL移入场价±2点(保本锁死)    |
//|    Phase 2: 利润≥InpTrailAActivate且<保本 → SL紧跟当前价±1点     |
//|                                                                  |
//|  模式B(一次性保本):                                                |
//|    利润≥InpTrailBTrigger → SL一次移到入场价±InpTrailBProtect点    |
//|    触发后锁死不再修改                                               |
//|                                                                  |
//|  互斥: A与B同时启用时A优先(在OnInit中已检查)                      |
//+------------------------------------------------------------------+
void CheckTrail()
{
   //--- 判断启用哪种模式
   bool useA = InpUseTrailA;
   bool useB = InpUseTrailB && !InpUseTrailA; // A优先,只有A关闭且B开启时才用B
   if(!useA && !useB) return;

   ulong ticket = GetMyPosTicket();
   if(ticket == 0)
   {
      g_trailFailCnt = 0;
      return;
   }

   //--- 失败达到上限则跳过(等待下次OnTimer/Tick重试)
   if(ticket == g_trailTicket && g_trailFailCnt > 5)
      return;

   //--- 获取持仓信息
   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currSL   = PositionGetDouble(POSITION_SL);
   double currTP   = PositionGetDouble(POSITION_TP);

   //--- 计算当前利润(点数)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitPoints = (posType == POSITION_TYPE_BUY)
                         ? (bid - openPrice) / g_pt
                         : (openPrice - ask) / g_pt;

   if(profitPoints <= 0) return;

   //===============================================================
   // 模式B: 一次性保本(触发后锁死)
   //===============================================================
   if(useB)
   {
      // B模式已触发锁定 → 不再修改
      if(g_trailBLocked) return;

      // 利润达到触发线 → 一次移动到入场价±保护点数,锁死
      if(profitPoints >= InpTrailBTrigger)
      {
         double newSL;
         if(posType == POSITION_TYPE_BUY)
            newSL = NormalizeDouble(openPrice + InpTrailBProtect * g_pt, g_dig);
         else
            newSL = NormalizeDouble(openPrice - InpTrailBProtect * g_pt, g_dig);

         // 只有当新SL比当前SL更有利时才修改
         bool needMove = (currSL == 0) ||
                         (posType == POSITION_TYPE_BUY && newSL > currSL) ||
                         (posType == POSITION_TYPE_SELL && newSL < currSL);
         if(needMove)
         {
            if(m_trade.PositionModify(ticket, newSL, currTP))
            {
               Print("🔒 追踪B(一次性保本): 利润=", DoubleToString(profitPoints, 0),
                     "点 SL:", DoubleToString(currSL, g_dig),
                     "→", DoubleToString(newSL, g_dig),
                     " 已锁定不再修改");
               g_trailBLocked = true;
               g_trailTicket  = ticket;
               g_trailFailCnt = 0;
               return;
            }
            else
            {
               Print("⚠️ 追踪B-修改SL失败: ticket=", ticket,
                     " retcode=", m_trade.ResultRetcode(),
                     " (", m_trade.ResultRetcodeDescription(), ")");
               g_trailFailCnt++;
               return;
            }
         }
      }
      // 利润未达标,不做任何操作
      return;
   }

   //===============================================================
   // 模式A: 渐进式(持续追踪SL)
   //===============================================================
   if(useA)
   {
      //--- Phase 1: 保本(利润≥保本点,直接移到入场价±2点,不再追踪)
      if(profitPoints >= InpTrailABreakeven)
      {
         double newSL;
         if(posType == POSITION_TYPE_BUY)
            newSL = NormalizeDouble(openPrice + 2 * g_pt, g_dig);
         else
            newSL = NormalizeDouble(openPrice - 2 * g_pt, g_dig);

         // 只有新SL更有利时才修改
         bool needMove = (currSL == 0) ||
                         (posType == POSITION_TYPE_BUY && newSL > currSL) ||
                         (posType == POSITION_TYPE_SELL && newSL < currSL);
         if(needMove)
         {
            if(m_trade.PositionModify(ticket, newSL, currTP))
            {
               Print("🔒 追踪A(保本): 利润=", DoubleToString(profitPoints, 0),
                     "点 SL:", DoubleToString(currSL, g_dig),
                     "→", DoubleToString(newSL, g_dig));
               g_trailTicket  = ticket;
               g_trailFailCnt = 0;
               return;
            }
            else
            {
               Print("⚠️ 追踪A-Phase1-修改SL失败: ticket=", ticket,
                     " retcode=", m_trade.ResultRetcode(),
                     " (", m_trade.ResultRetcodeDescription(), ")");
               g_trailFailCnt++;
               return;
            }
         }
         return;
      }

      //--- Phase 2: 渐进追踪(利润≥激活点且<保本点)
      if(profitPoints >= InpTrailAActivate)
      {
         double newSL;
         if(posType == POSITION_TYPE_BUY)
            newSL = NormalizeDouble(bid - 1 * g_pt, g_dig);
         else
            newSL = NormalizeDouble(ask + 1 * g_pt, g_dig);

         // 只有新SL更有利时才修改
         bool needMove = (currSL == 0) ||
                         (posType == POSITION_TYPE_BUY && newSL > currSL) ||
                         (posType == POSITION_TYPE_SELL && newSL < currSL);
         if(needMove)
         {
            if(m_trade.PositionModify(ticket, newSL, currTP))
            {
               Print("📈 追踪A(渐进): 利润=", DoubleToString(profitPoints, 0),
                     "点 SL:", DoubleToString(currSL, g_dig),
                     "→", DoubleToString(newSL, g_dig));
               g_trailTicket  = ticket;
               g_trailFailCnt = 0;
            }
            else
            {
               Print("⚠️ 追踪A-Phase2-修改SL失败: ticket=", ticket,
                     " retcode=", m_trade.ResultRetcode(),
                     " (", m_trade.ResultRetcodeDescription(), ")");
               g_trailFailCnt++;
            }
         }
         return;
      }
   }
}
//+------------------------------------------------------------------+
