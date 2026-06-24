//+------------------------------------------------------------------+
//|                                        EMA55_SuperTrend_共振.mq5 |
//|                                          Senior Developer        |
//|                                                                  |
//|  策略: M5 EMA55趋势判断 + M1 SuperTrend共振回踩入场               |
//|                                                                  |
//|  【趋势判断 - M5】                                                |
//|    连续2根5分钟K线收盘价>EMA55 = 多头趋势                         |
//|    连续2根5分钟K线收盘价<EMA55 = 空头趋势                         |
//|    多头趋势只做多,空头趋势只做空                                  |
//|                                                                  |
//|  【入场 - M1】                                                    |
//|    多头共振: M5多头 + M1 SuperTrend多头 + 价格回踩ST线±$0.5开多  |
//|    空头共振: M5空头 + M1 SuperTrend空头 + 价格回踩ST线±$0.5开空  |
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
#property version   "1.11"
#property description "M5 EMA55趋势 + M1 SuperTrend共振回踩入场"
#property description "M5:连续2K收盘>55EMA=多头,收盘<55EMA=空头"
#property description "M1:SuperTrend与M5趋势共振+回踩ST线$0.5内开仓"
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

input group   "=== ★ 追踪止损 ==="
input bool    InpUseTrailing     = true;            // 启用追踪止损
input int     InpTrailActivate   = 200;             // 追踪激活点数
input int     InpTrailDistance   = 700;             // 追踪距离点数(700点保本)
input int     InpTrailCooldownMs = 1000;            // 追踪止损失败重试冷却(毫秒)

//+------------------------------------------------------------------+
//| 全局变量                                                         |
//+------------------------------------------------------------------+
CTrade      m_trade;
int         g_hMA55   = INVALID_HANDLE;   // M5 55EMA指标句柄
int         g_hATR    = INVALID_HANDLE;   // M1 ATR指标句柄(用于SuperTrend)

//--- 趋势枚举
enum ENUM_TREND { TREND_NONE, TREND_BULL, TREND_BEAR };

ENUM_TREND  g_trendM5    = TREND_NONE;    // M5趋势
datetime    g_lastM5Bar  = 0;             // 上次处理的M5K线时间
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

//--- 缓存数据
double      g_pt         = 0.0;           // 点值
int         g_dig        = 0;             // 小数位数

//--- 追踪止损状态(防高频修改)
ulong       g_lastTrailTicket = 0;        // 上次修改的持仓ticket
datetime    g_lastTrailTime   = 0;        // 上次修改时间
int         g_trailRetryCount = 0;        // 连续失败次数

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

   //--- 创建指标
   g_hMA55 = iMA(_Symbol, PERIOD_M5, 55, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR  = iATR(_Symbol, PERIOD_M1, InpSTPeriod);
   if(g_hMA55 == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      Print("❌ 创建指标失败,请检查是否连接到行情");
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
   g_lastM5Bar = iTime(_Symbol, PERIOD_M5, 0);
   g_lastM1Bar = iTime(_Symbol, PERIOD_M1, 0);

   //--- 初始化风控
   ResetDay();

   //--- 创建定时器(每2秒处理一次,保障无Tick时也能运行追踪止损)
   g_timerId = EventSetMillisecondTimer(2000);
   if(g_timerId < 0)
   {
      Print("⚠️ 定时器创建失败,将仅依赖OnTick运行");
   }

   //--- 打印启动信息
   Print("╔══════════════════════════════════════════╗");
   Print("║   M5 EMA55 + M1 SuperTrend 共振EA v1.10 ║");
   Print("╠══════════════════════════════════════════╣");
   Print("║ 服务器时间: ", TimeToString(TimeCurrent()));
   Print("║ 北京时间:   ", TimeToString(TimeCurrent() + g_bjOffset));
   Print("║ 交易品种:   ", _Symbol);
   Print("║ 止损:       ", InpStopLoss, "点 (", InpStopLoss*10, "美分)");
   Print("║ 止盈:       ", InpTakeProfit, "点 (", InpTakeProfit*10, "美分)");
   Print("║ 触碰距离:   ", InpTouchDistance, " USD");
   Print("║ ST周期/倍数: ", InpSTPeriod, "/", InpSTMultiplier);
   Print("║ 追踪冷却:   ", InpTrailCooldownMs, "ms");
   Print("╚══════════════════════════════════════════╝");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 反初始化                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_timerId >= 0)
      EventKillTimer();

   if(g_hMA55 != INVALID_HANDLE) IndicatorRelease(g_hMA55);
   if(g_hATR  != INVALID_HANDLE) IndicatorRelease(g_hATR);

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

   //--- 已有持仓则不开新仓
   if(HasMyPos()) return;

   //--- 点差检查
   if(!CheckSpread()) return;

   //--- 更新M5趋势
   UpdateTrendM5();

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

   //--- 交易时间检查
   if(!IsTradeTime()) return;

   //--- 当日亏损检查
   if(!CheckDayLoss()) return;

   //--- 已有持仓追踪止损
   CheckTrail();

   //--- 检查是否已有持仓(一次只交易一单)
   if(HasMyPos()) return;

   //--- 点差检查
   if(!CheckSpread()) return;

   //--- 更新M5趋势
   UpdateTrendM5();

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
   g_trailRetryCount = 0;
   g_lastTrailTicket = 0;

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
//| M5 55EMA趋势判断                                                  |
//|  连续2根K线收盘价>55EMA = 多头                                    |
//|  连续2根K线收盘价<55EMA = 空头                                    |
//|  不满足条件则保持原趋势(防毛刺)                                    |
//+------------------------------------------------------------------+
void UpdateTrendM5()
{
   datetime curBar = iTime(_Symbol, PERIOD_M5, 0);
   if(curBar == 0)
   {
      // 数据尚未就绪,跳过
      return;
   }
   if(curBar == g_lastM5Bar && !g_firstRun) return;
   g_lastM5Bar = curBar;

   //--- 获取足够的数据(使用已完成K线)
   double close[4], ema[4];
   int copied = CopyClose(_Symbol, PERIOD_M5, 0, 4, close);
   if(copied < 4)
   {
      Print("⚠️ M5 Close数据不足: ", copied);
      return;
   }
   int bufCopied = CopyBuffer(g_hMA55, 0, 0, 4, ema);
   if(bufCopied < 4)
   {
      Print("⚠️ M5 EMA数据不足: ", bufCopied);
      return;
   }

   //--- 检查数据有效性(防止边界值)
   if(close[1] <= 0 || close[2] <= 0 || ema[1] <= 0 || ema[2] <= 0)
   {
      Print("⚠️ M5 数据异常,跳过趋势更新");
      return;
   }

   //--- 注意: bar[0]是当前未完成K线,用bar[1]和bar[2]判断
   //    bar[1] = 上一根已完成K线
   //    bar[2] = 上两根已完成K线
   ENUM_TREND oldTrend = g_trendM5;

   if(close[1] > ema[1] && close[2] > ema[2])
   {
      g_trendM5 = TREND_BULL;
   }
   else if(close[1] < ema[1] && close[2] < ema[2])
   {
      g_trendM5 = TREND_BEAR;
   }
   // 不满足条件保持原趋势,避免频繁切换

   if(g_trendM5 != oldTrend)
   {
      Print("📊 M5趋势切换: ", 
            (oldTrend == TREND_BULL ? "多头→" : oldTrend == TREND_BEAR ? "空头→" : "无→"),
            (g_trendM5 == TREND_BULL ? "多头" : "空头"),
            " 价格: ", DoubleToString(close[1], g_dig),
            " EMA55: ", DoubleToString(ema[1], g_dig));
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
      // ATR为0时无法计算有效Band,跳过
      return;
   }

   //--- 使用已完成K线(bar[1])的数据
   double hi   = iHigh(_Symbol, PERIOD_M1, 1);
   double lo   = iLow(_Symbol, PERIOD_M1, 1);
   double cl   = iClose(_Symbol, PERIOD_M1, 1);
   if(hi <= 0 || lo <= 0 || cl <= 0)
   {
      // 数据尚未就绪
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
         // 第一根K线: 初始化方向
         g_stUp = (cl > dnBand);
         g_stValue = g_stUp ? dnBand : upBand;
      }
      else // g_stReady == 2
      {
         // 第二根K线: 重新校准方向
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
      // 当前多头: 收盘 > ST线 → 维持多头,否则翻空(⚠️与ST线本身比较,非原始下轨)
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
      // 当前空头: 收盘 < ST线 → 维持空头,否则翻多(⚠️与ST线本身比较,非原始上轨)
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
//| 入场条件检查                                                      |
//|                                                                  |
//|  核心逻辑:                                                        |
//|  1. M5趋势与M1 SuperTrend方向一致(共振)                           |
//|  2. 价格回踩到SuperTrend线附近(±$0.5)                             |
//|  3. 不追高/不追空,只在回调时入场                                  |
//|                                                                  |
//|  多头入场: M5多头 + ST多头 + 价格回踩ST线                         |
//|  空头入场: M5空头 + ST空头 + 价格回踩ST线                         |
//+------------------------------------------------------------------+
void CheckEntry()
{
   //--- M1新K线时更新SuperTrend
   datetime curM1Bar = iTime(_Symbol, PERIOD_M1, 0);
   if(curM1Bar == 0) return;
   if(curM1Bar != g_lastM1Bar)
   {
      g_lastM1Bar = curM1Bar;
      UpdateST();
      g_entryBlock = false;
   }

   //--- SuperTrend未就绪或趋势未确立
   if(g_stReady < 2) return;
   if(g_trendM5 == TREND_NONE) return;

   //--- 同一根M1K线只入场一次
   if(g_entryBlock) return;

   //--- 检查共振: ST方向必须与M5趋势一致
   bool isBullAligned = (g_trendM5 == TREND_BULL && g_stUp);
   bool isBearAligned = (g_trendM5 == TREND_BEAR && !g_stUp);

   if(!isBullAligned && !isBearAligned)
   {
      //--- 诊断日志: 每5分钟打印一次当前状态,帮助排查为何不开单
      static datetime s_lastDiagLog = 0;
      if(s_lastDiagLog != curM1Bar && (curM1Bar % 300) == 0) // 每5个M1 bar ≈ 每5分钟
      {
         s_lastDiagLog = curM1Bar;
         string m5Str = (g_trendM5 == TREND_BULL ? "多头" :
                        g_trendM5 == TREND_BEAR ? "空头" : "无趋势");
         string stStr = g_stUp ? "多头(↑)" : "空头(↓)";
         Print("📋 诊断: M5=", m5Str, " ST=", stStr,
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
         Print("   M5趋势=多头  ST趋势=多头(↑) ST线=", DoubleToString(g_stValue, g_dig));
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
         Print("   M5趋势=空头  ST趋势=空头(↓) ST线=", DoubleToString(g_stValue, g_dig));
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

   //--- 修正SL/TP以满足最小距离要求
   FixSLTP(ask, true, sl, tp);

   //--- 最终有效性校验
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

   //--- 修正SL/TP以满足最小距离要求
   FixSLTP(bid, false, sl, tp);

   //--- 最终有效性校验
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

   //--- 限制最小距离
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

   //--- 防止SL/TP被修正到不合理的位置
   double maxStopDistance = entryPrice + 10000 * g_pt; // 上限保护
   double minStopDistance = entryPrice - 10000 * g_pt; // 下限保护
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

   //--- 固定手数模式
   if(InpUseFixedLot)
   {
      lot = InpFixedLot;
   }
   //--- 百分比风险模式
   else
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance <= 0)
      {
         Print("⚠️ 账户余额异常(", DoubleToString(balance, 2), "),使用固定手数: ", InpFixedLot);
         return InpFixedLot;
      }

      double riskMoney = balance * InpRiskPercent / 100.0;

      // 计算每点价值
      double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickValue <= 0 || tickSize <= 0 || g_pt <= 0)
      {
         Print("⚠️ 无法计算点值(tv=", tickValue, " ts=", tickSize, " pt=", g_pt,
               "),使用固定手数: ", InpFixedLot);
         return InpFixedLot;
      }

      // 每点的价值(以账户货币计)
      double pointValue = tickValue / tickSize * g_pt;
      if(pointValue <= 0)
      {
         Print("⚠️ 点值计算异常(pv=", pointValue, "),使用固定手数: ", InpFixedLot);
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

   //--- 规范化到可交易手数
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0)
      lot = MathFloor(lot / step) * step;

   //--- 获取交易所限制
   double exchMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double exchMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(exchMin <= 0) exchMin = InpMinLot;
   if(exchMax <= 0) exchMax = InpMaxLot;

   //--- 取最严格的上下限(用户设置vs交易所限制)
   double finalMin = MathMax(InpMinLot, exchMin);
   double finalMax = MathMin(InpMaxLot, exchMax);

   lot = MathMax(lot, finalMin);
   lot = MathMin(lot, finalMax);

   //--- 可用保证金校验(百分比模式额外检查)
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
            Print("   尝试使用可用保证金90%计算手数");
            // 重算: 用90%可用保证金的安全手数
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
//| 追踪止损                                                         |
//|                                                                  |
//|  规则:                                                            |
//|  1. 利润达到200点时激活追踪止损                                   |
//|  2. 追踪距离700点                                                |
//|  3. 当利润达到700点时,止损恰好移动到开仓位(保本)                  |
//|  4. 止盈位不动                                                    |
//|                                                                  |
//|  计算: 多单新SL = 当前Bid - 700点                                 |
//|        空单新SL = 当前Ask + 700点                                 |
//|                                                                  |
//|  防高频: 同ticket连续修改间隔不低于InpTrailCooldownMs             |
//+------------------------------------------------------------------+
void CheckTrail()
{
   if(!InpUseTrailing) return;

   ulong ticket = GetMyPosTicket();
   if(ticket == 0)
   {
      g_trailRetryCount = 0;
      return;
   }

   //--- 检查冷却(同持仓修改过于频繁则跳过)
   if(ticket == g_lastTrailTicket && g_trailRetryCount > 5)
   {
      // 连续失败次数过多,等待新Tick再试
      return;
   }

   //--- 冷却时间检查
   if(ticket == g_lastTrailTicket && g_lastTrailTime > 0)
   {
      datetime now = TimeCurrent();
      if((now - g_lastTrailTime) * 1000 < InpTrailCooldownMs)
         return;
   }

   //--- 获取持仓信息
   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currSL   = PositionGetDouble(POSITION_SL);
   double currTP   = PositionGetDouble(POSITION_TP);

   bool modified = false;

   if(posType == POSITION_TYPE_BUY)
   {
      //--- 多单追踪
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profitPoints = (bid - openPrice) / g_pt;

      if(profitPoints >= InpTrailActivate)
      {
         double newSL = NormalizeDouble(bid - InpTrailDistance * g_pt, g_dig);
         double origSL = NormalizeDouble(openPrice - InpStopLoss * g_pt, g_dig);

         // 新SL必须高于当前SL且高于原始SL(只上移)
         if(newSL > currSL && newSL > origSL)
         {
            if(m_trade.PositionModify(ticket, newSL, currTP))
            {
               Print("📈 多单追踪止损: 利润=", DoubleToString(profitPoints, 0),
                     "点 SL:", DoubleToString(currSL, g_dig),
                     "→", DoubleToString(newSL, g_dig));
               g_lastTrailTicket = ticket;
               g_lastTrailTime   = TimeCurrent();
               g_trailRetryCount = 0;
               modified = true;
            }
            else
            {
               // 记录失败,但重试
               g_trailRetryCount++;
               g_lastTrailTime = TimeCurrent();
            }
         }
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      //--- 空单追踪
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (openPrice - ask) / g_pt;

      if(profitPoints >= InpTrailActivate)
      {
         double newSL = NormalizeDouble(ask + InpTrailDistance * g_pt, g_dig);
         double origSL = NormalizeDouble(openPrice + InpStopLoss * g_pt, g_dig);

         // 新SL必须低于当前SL(无SL时currSL=0)且低于原始SL(只下移)
         bool slValid = (currSL == 0) || (newSL < currSL);
         if(slValid && newSL < origSL)
         {
            if(m_trade.PositionModify(ticket, newSL, currTP))
            {
               Print("📉 空单追踪止损: 利润=", DoubleToString(profitPoints, 0),
                     "点 SL:", DoubleToString(currSL, g_dig),
                     "→", DoubleToString(newSL, g_dig));
               g_lastTrailTicket = ticket;
               g_lastTrailTime   = TimeCurrent();
               g_trailRetryCount = 0;
               modified = true;
            }
            else
            {
               g_trailRetryCount++;
               g_lastTrailTime = TimeCurrent();
            }
         }
      }
   }

   //--- 未修改时保持冷却状态但不递增重试计数
   if(!modified && ticket == g_lastTrailTicket)
   {
      g_lastTrailTime = TimeCurrent();
   }
}
//+------------------------------------------------------------------+
