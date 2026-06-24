//+------------------------------------------------------------------+
//|                                     EMA55_MA233_形态_共振.mq5     |
//|                                          Senior Developer         |
//|                                                                  |
//|  策略: 1M EMA55/MA233金叉死叉趋势 + K线形态/123法则共振入场      |
//|                                                                  |
//|  【趋势判断 - 1M】                                                |
//|    EMA55上穿MA233 = 多头趋势, 只做多不追高                        |
//|    EMA55下穿MA233 = 空头趋势, 只做空不追空                        |
//|                                                                  |
//|  【入场 - 1M 形态/123法则】                                       |
//|    多头趋势中: 回调形成W底/头肩底/123多头 → 破颈线 → 下根K开多   |
//|    空头趋势中: 反弹形成M顶/头肩顶/123空头 → 破颈线 → 下根K开空   |
//|                                                                  |
//|  【出场】                                                         |
//|    止损: 颈线±300点(3美金) | 止盈: 入场±1200点(12美金)          |
//|    追踪止损: 200点激活 → 500点保本                                |
//|                                                                  |
//|  【风控】                                                         |
//|    交易时间: 北京时间 07:30 ~ 次日03:30                           |
//|    仓位管理: 固定手数/百分比, 最大手数限制                        |
//|    当日最大亏损限制, 点差限制                                     |
//+------------------------------------------------------------------+
#property copyright "Senior Developer"
#property version   "1.00"
#property description "1M EMA55/MA233趋势 + K线形态/123法则共振EA"
#property description "多头:W底/头肩底/123破颈线开多 | 空头:M顶/头肩顶/123破颈线开空"
#property description "止损:颈线±300点 | 止盈:1200点 | 追踪:200激活500保本"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 输入参数                                                         |
//+------------------------------------------------------------------+
input group   "=== ★ 策略核心参数 ==="
input int     InpMagicNumber     = 20260525;        // 魔法编号
input double  InpStopLossPts     = 300;             // 止损距颈线(点数,300=3美金)
input double  InpTakeProfitPts   = 1200;            // 止盈点数(1200=12美金)
input int     InpSwingLookback   = 5;               // 摆动点识别回看K线数
input double  InpSwingMinPts     = 30;              // 最小摆动幅度(点数)
input double  InpNecklineTolPct  = 0.3;             // 颈线容差(%价格)
input int     InpPatternExpire   = 30;              // 形态失效时间(K线数)

input group   "=== ★ 趋势参数 ==="
input int     InpEMAPeriod       = 55;              // EMA快线周期
input int     InpMAPeriod        = 233;             // MA慢线周期

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
input int     InpTrailActivate   = 200;             // 追踪激活点数(200点)
input int     InpTrailDistance   = 500;             // 追踪距离点数(500点保本)
input int     InpTrailCooldownMs = 1000;            // 追踪止损失败重试冷却(毫秒)

//+------------------------------------------------------------------+
//| 枚举与结构体                                                     |
//+------------------------------------------------------------------+
enum ENUM_TREND { TREND_NONE, TREND_BULL, TREND_BEAR };

//--- 摆动点
struct SwingPoint
{
   int      idx;          // 相对当前K线的索引(正数=历史)
   double   price;        // 价格
   datetime time;         // 时间
   int      type;         // 1=高点 -1=低点
};

//--- 已识别形态
struct PatternInfo
{
   int      patType;      // 0=W底 1=M顶 2=头肩底 3=头肩顶 4=123多头 5=123空头
   double   neckline;     // 颈线价格
   datetime formTime;     // 形态完成时间(K线时间)
   datetime expireTime;   // 形态失效时间
   bool     active;       // 形态是否仍有效
};

//+------------------------------------------------------------------+
//| 全局变量                                                         |
//+------------------------------------------------------------------+
CTrade         m_trade;
int            g_hEMA55       = INVALID_HANDLE;   // 1M 55EMA句柄
int            g_hMA233       = INVALID_HANDLE;   // 1M 233MA句柄

//--- 趋势
ENUM_TREND     g_trend        = TREND_NONE;       // 当前趋势
bool           g_trendInit    = false;            // 趋势是否已初始化
double         g_prevEMA55    = 0;                // 上根K线EMA55值
double         g_prevMA233    = 0;                // 上根K线MA233值

//--- 摆动点
SwingPoint     g_swings[20];                      // 最近摆动点(最多20个)
int            g_swingCount   = 0;                // 摆动点数量

//--- 形态跟踪
PatternInfo    g_patterns[5];                     // 活跃形态(最多5个)
int            g_patCount     = 0;                // 活跃形态数量

//--- 入场状态
bool           g_entryPending = false;            // 颈线已突破,等待入场
int            g_entryDir     = 0;                // 待入场方向: 1=多 -1=空
double         g_entryNeckline = 0;               // 入场对应的颈线价格

//--- K线追踪
datetime       g_lastBar      = 0;                // 上次处理的K线时间
datetime       g_breakBar     = 0;                // 破颈线那根K线的时间

//--- 北京时间
int            g_bjOffset     = 0;                // 北京时间偏移(秒)
bool           g_firstRun     = true;             // 首次运行标记

//--- 风控
double         g_dayBal       = 0;                // 当日初始余额
int            g_dayNum       = -1;               // 当前日序号
bool           g_dayLimit     = false;            // 当日是否已达亏损限制

//--- 持仓/追踪
ulong          g_trailTicket   = 0;               // 追踪止损的持仓ticket
datetime       g_trailTime     = 0;               // 上次追踪止损时间
int            g_trailRetries  = 0;               // 追踪失败重试次数

//--- 缓存
double         g_pt           = 0;                // 点值
int            g_dig          = 0;                // 小数位数
int            g_timerId      = -1;               // 定时器ID

//--- 诊断日志
datetime       g_lastDiagLog  = 0;                // 上次诊断日志时间

//+------------------------------------------------------------------+
//| 初始化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 交易设置
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(50);
   m_trade.SetAsyncMode(false);

   //--- 缓存
   g_pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- 参数校验
   if(InpStopLossPts <= 0 || InpTakeProfitPts <= 0)
   {
      Print("❌ 止损/止盈必须大于0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSwingLookback < 2)
   {
      Print("❌ 摆动点回看K线数必须≥2");
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- 创建指标
   g_hEMA55 = iMA(_Symbol, PERIOD_M1, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hMA233 = iMA(_Symbol, PERIOD_M1, InpMAPeriod,  0, MODE_SMA, PRICE_CLOSE);
   if(g_hEMA55 == INVALID_HANDLE || g_hMA233 == INVALID_HANDLE)
   {
      Print("❌ 创建指标失败");
      return INIT_FAILED;
   }

   //--- 北京时间偏移
   int srvGmtOffset = (int)(TimeCurrent() - TimeGMT());
   g_bjOffset = 8 * 3600 - srvGmtOffset;
   if(MathAbs(g_bjOffset - 5*3600) > 1800)
   {
      Print("ℹ️ 服务器与北京时间偏差=", g_bjOffset/3600, "小时,请核实交易时间设置");
   }

   //--- 初始化
   g_lastBar = iTime(_Symbol, PERIOD_M1, 0);
   ResetDay();

   //--- 定时器(2秒)
   g_timerId = EventSetMillisecondTimer(2000);

   //--- 预热趋势(需要等待足够的历史数据)
   InitTrend();

   //--- 打印启动信息
   Print("╔══════════════════════════════════════════╗");
   Print("║ EMA55/MA233 + 形态/123法则 共振EA v1.00 ║");
   Print("╠══════════════════════════════════════════╣");
   Print("║ 服务器时间: ", TimeToString(TimeCurrent()));
   Print("║ 北京时间:   ", TimeToString(TimeCurrent() + g_bjOffset));
   Print("║ 交易品种:   ", _Symbol);
   Print("║ 止损(颈线±):", InpStopLossPts, "点 = ", InpStopLossPts*10, "美分");
   Print("║ 止盈(入场±):", InpTakeProfitPts, "点 = ", InpTakeProfitPts*10, "美分");
   Print("║ 趋势:       EMA", InpEMAPeriod, "/MA", InpMAPeriod);
   Print("║ 摆动回看:   ", InpSwingLookback, "K | 最小幅度:", InpSwingMinPts, "点");
   Print("║ 形态失效:   ", InpPatternExpire, "K线");
   Print("║ 追踪:", InpTrailActivate, "激活", InpTrailDistance, "保本");
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

   if(g_hEMA55 != INVALID_HANDLE) IndicatorRelease(g_hEMA55);
   if(g_hMA233 != INVALID_HANDLE) IndicatorRelease(g_hMA233);

   Print("📌 EA已停止,原因代码: ", reason);
}

//+------------------------------------------------------------------+
//| 定时器                                                           |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateDay();
   if(g_dayLimit) { CheckTrail(); return; }
   if(!IsTradeTime()) return;
   if(!CheckDayLoss()) return;

   //--- 无持仓时检查入场
   if(!HasMyPos())
   {
      if(!CheckSpread()) return;
      ProcessBar();
      CheckEntry();
   }
   else
   {
      CheckTrail();
   }
}

//+------------------------------------------------------------------+
//| 主Tick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDay();
   if(g_dayLimit) { CheckTrail(); return; }
   if(!IsTradeTime()) return;
   if(!CheckDayLoss()) return;

   if(!HasMyPos())
   {
      if(!CheckSpread()) return;
      ProcessBar();
      CheckEntry();
   }
   else
   {
      CheckTrail();
   }
}

//+==================================================================+
//| 模块1: 趋势判断 (EMA55 vs MA233 金叉死叉)                        |
//+==================================================================+

//+------------------------------------------------------------------+
//| 初始化趋势(预热)                                                   |
//+------------------------------------------------------------------+
void InitTrend()
{
   double ema[2], ma[2];
   if(CopyBuffer(g_hEMA55, 0, 1, 2, ema) < 2) return;
   if(CopyBuffer(g_hMA233, 0, 1, 2, ma)  < 2) return;

   g_prevEMA55 = ema[1];
   g_prevMA233 = ma[1];

   if(ema[1] > ma[1])
      g_trend = TREND_BULL;
   else if(ema[1] < ma[1])
      g_trend = TREND_BEAR;

   g_trendInit = true;

   Print("📊 趋势初始化: ", (g_trend == TREND_BULL ? "多头" :
                          g_trend == TREND_BEAR ? "空头" : "未确立"),
         " EMA55=", DoubleToString(ema[1], g_dig),
         " MA233=", DoubleToString(ma[1], g_dig));
}

//+------------------------------------------------------------------+
//| 更新趋势(基于金叉死叉)                                             |
//|  在新K线完成时调用,用已完成K线(索引1)的EMA55/MA233判断            |
//+------------------------------------------------------------------+
void UpdateTrend()
{
   double ema[2], ma[2];
   if(CopyBuffer(g_hEMA55, 0, 1, 2, ema) < 2) return;
   if(CopyBuffer(g_hMA233, 0, 1, 2, ma)  < 2) return;

   if(ema[1] <= 0 || ma[1] <= 0) return;

   double curEMA55 = ema[1];   // 上根已完成K线的EMA55
   double curMA233 = ma[1];    // 上根已完成K线的MA233

   //--- 趋势未初始化
   if(!g_trendInit)
   {
      g_prevEMA55 = curEMA55;
      g_prevMA233 = curMA233;
      if(curEMA55 > curMA233) g_trend = TREND_BULL;
      else if(curEMA55 < curMA233) g_trend = TREND_BEAR;
      g_trendInit = true;
      Print("📊 趋势初始化: ", (g_trend == TREND_BULL ? "多头" : "空头"),
            " EMA55=", DoubleToString(curEMA55, g_dig),
            " MA233=", DoubleToString(curMA233, g_dig));
      return;
   }

   //--- 金叉: EMA55由下向上穿越MA233
   if(g_prevEMA55 <= g_prevMA233 && curEMA55 > curMA233)
   {
      ENUM_TREND old = g_trend;
      g_trend = TREND_BULL;
      if(old != TREND_BULL)
      {
         ClearPatterns();  // 趋势反转,清除旧形态
         Print("🟢 金叉! EMA55(", DoubleToString(curEMA55, g_dig),
               ") 上穿 MA233(", DoubleToString(curMA233, g_dig), ")");
         Print("   趋势→多头, 只做多, 等待回调形态");
      }
   }
   //--- 死叉: EMA55由上向下穿越MA233
   else if(g_prevEMA55 >= g_prevMA233 && curEMA55 < curMA233)
   {
      ENUM_TREND old = g_trend;
      g_trend = TREND_BEAR;
      if(old != TREND_BEAR)
      {
         ClearPatterns();
         Print("🔴 死叉! EMA55(", DoubleToString(curEMA55, g_dig),
               ") 下穿 MA233(", DoubleToString(curMA233, g_dig), ")");
         Print("   趋势→空头, 只做空, 等待反弹形态");
      }
   }

   g_prevEMA55 = curEMA55;
   g_prevMA233 = curMA233;
}

//+==================================================================+
//| 模块2: 摆动点识别                                                |
//+==================================================================+

//+------------------------------------------------------------------+
//| 扫描摆动点                                                        |
//|  扫描最近80根K线,找出局部极值点                                    |
//+------------------------------------------------------------------+
void ScanSwings()
{
   g_swingCount = 0;
   // ZeroMemory 对静态结构体数组归零
   ZeroMemory(g_swings);

   int totalBars = MathMin(Bars(_Symbol, PERIOD_M1), 80);
   if(totalBars < InpSwingLookback * 2 + 1) return;

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, PERIOD_M1, 0, totalBars, highs) < totalBars) return;
   if(CopyLow(_Symbol, PERIOD_M1, 0, totalBars, lows)   < totalBars) return;
   if(ArraySize(highs) < totalBars || ArraySize(lows) < totalBars) return;

   datetime times[];
   ArraySetAsSeries(times, true);
   if(CopyTime(_Symbol, PERIOD_M1, 0, totalBars, times) < totalBars) return;

   int lb = InpSwingLookback;

   //--- 从右向左扫描(跳过最右lb根和最左lb根)
   for(int i = lb; i < totalBars - lb && g_swingCount < 20; i++)
   {
      if(highs[i] <= 0 || lows[i] <= 0) continue;

      //--- 检查是否为局部高点
      bool isHigh = true;
      for(int j = 1; j <= lb; j++)
      {
         if(highs[i-j] >= highs[i] || highs[i+j] >= highs[i])
         { isHigh = false; break; }
      }

      //--- 检查是否为局部低点
      bool isLow = true;
      for(int j = 1; j <= lb; j++)
      {
         if(lows[i-j] <= lows[i] || lows[i+j] <= lows[i])
         { isLow = false; break; }
      }

      //--- 不能同时是高点又是低点(间隔太近取振幅大者)
      if(isHigh && isLow)
      {
         double ampH = highs[i] - MathMin(lows[i-lb], lows[i+lb]);
         double ampL = MathMax(highs[i-lb], highs[i+lb]) - lows[i];
         if(ampH >= ampL)
            isLow = false;
         else
            isHigh = false;
      }

      //--- 存储摆动高点
      if(isHigh)
      {
         g_swings[g_swingCount].idx   = i;
         g_swings[g_swingCount].price = highs[i];
         g_swings[g_swingCount].time  = times[i];
         g_swings[g_swingCount].type  = 1;
         g_swingCount++;
      }

      //--- 存储摆动低点
      if(isLow)
      {
         g_swings[g_swingCount].idx   = i;
         g_swings[g_swingCount].price = lows[i];
         g_swings[g_swingCount].time  = times[i];
         g_swings[g_swingCount].type  = -1;
         g_swingCount++;
      }
   }
}

//+==================================================================+
//| 模块3: 形态识别                                                   |
//+==================================================================+

//+------------------------------------------------------------------+
//| 价格容差检查(两个价格是否在容差范围内视为相等)                      |
//+------------------------------------------------------------------+
bool PriceNear(double a, double b)
{
   if(b == 0) return false;
   return MathAbs(a - b) / b * 100.0 <= InpNecklineTolPct;
}

//+------------------------------------------------------------------+
//| 获取最近N个摆动点(按时间从远到近排列)                               |
//|  在g_swings[]中搜索,返回指定类型的最近N个点                         |
//+------------------------------------------------------------------+
int GetRecentSwings(SwingPoint &out[], int count)
{
   int found = 0;
   ArrayResize(out, 0);

   // g_swings已经是按时间从远到近排列(idx从大到小)
   // 取最后count个(即最近的count个)
   for(int i = g_swingCount - 1; i >= 0 && found < count; i--)
   {
      ArrayResize(out, found + 1);
      out[found] = g_swings[i];
      found++;
   }
   return found;
}

//+------------------------------------------------------------------+
//| 检测W底 (双底)                                                     |
//|                                                                  |
//|  模式: 低点(L1) → 高点(H) → 低点(L2)                              |
//|  条件:                                                            |
//|    1. L1和L2价格接近(容差内)                                       |
//|    2. H明显高于两个低点(至少满足最小摆动幅度)                        |
//|    3. L2 >= L1 (右底不低于左底)                                    |
//|  颈线 = H的价格                                                    |
//|  返回: true=检测到形态, neckline已设置                              |
//+------------------------------------------------------------------+
bool DetectWBottom(double &neckline, double &swingLowPrice)
{
   if(g_swingCount < 3) return false;

   SwingPoint sw[4];
   int n = GetRecentSwings(sw, 4);

   //--- 需要至少3个点,且最后3个必须是: 低 → 高 → 低
   if(n < 3) return false;
   if(sw[2].type != -1 || sw[1].type != 1 || sw[0].type != -1)
      return false;

   //--- 检查距离(价格幅度)
   double ampH = sw[1].price - sw[2].price;  // 高-左低
   double ampR = sw[1].price - sw[0].price;  // 高-右低
   if(ampH < InpSwingMinPts * g_pt) return false;
   if(ampR < InpSwingMinPts * g_pt) return false;

   //--- 两底价格接近
   if(!PriceNear(sw[2].price, sw[0].price)) return false;

   //--- 右底不低于左底
   if(sw[0].price < sw[2].price) return false;

   //--- 确认回调: 当前价格应低于颈线(在回调区域)
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(curPrice > sw[1].price) return false;

   neckline = sw[1].price;
   swingLowPrice = MathMin(sw[2].price, sw[0].price);

   return true;
}

//+------------------------------------------------------------------+
//| 检测M顶 (双顶)                                                     |
//|                                                                  |
//|  模式: 高点(H1) → 低点(L) → 高点(H2)                              |
//|  颈线 = L的价格                                                    |
//+------------------------------------------------------------------+
bool DetectMTop(double &neckline, double &swingHighPrice)
{
   if(g_swingCount < 3) return false;

   SwingPoint sw[4];
   int n = GetRecentSwings(sw, 4);

   if(n < 3) return false;
   if(sw[2].type != 1 || sw[1].type != -1 || sw[0].type != 1)
      return false;

   double ampH1 = sw[2].price - sw[1].price;
   double ampH2 = sw[0].price - sw[1].price;
   if(ampH1 < InpSwingMinPts * g_pt) return false;
   if(ampH2 < InpSwingMinPts * g_pt) return false;

   if(!PriceNear(sw[2].price, sw[0].price)) return false;

   // 右顶不高于左顶
   if(sw[0].price > sw[2].price) return false;

   // 确认反弹: 当前价格应高于颈线
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(curPrice < sw[1].price) return false;

   neckline = sw[1].price;
   swingHighPrice = MathMax(sw[2].price, sw[0].price);

   return true;
}

//+------------------------------------------------------------------+
//| 检测头肩底 (倒头肩顶)                                              |
//|                                                                  |
//|  模式: 低点(左肩) → 高点 → 低点(头,更低) → 高点 → 低点(右肩)       |
//|  颈线: 连接两个反弹高点的水平线(取均值)                             |
//+------------------------------------------------------------------+
bool DetectInvHeadShoulders(double &neckline, double &swingLowPrice)
{
   if(g_swingCount < 5) return false;

   SwingPoint sw[6];
   int n = GetRecentSwings(sw, 6);
   if(n < 5) return false;

   // 模式: 低 → 高 → 低 → 高 → 低
   if(sw[4].type != -1 || sw[3].type != 1 || sw[2].type != -1 ||
      sw[1].type != 1  || sw[0].type != -1)
      return false;

   // 头(sw[2])必须低于左肩(sw[4])和右肩(sw[0])
   if(sw[2].price >= sw[4].price) return false;
   if(sw[2].price >= sw[0].price) return false;

   // 两个反弹高点(sw[3], sw[1])应接近
   if(!PriceNear(sw[3].price, sw[1].price)) return false;

   // 左右肩应接近
   if(!PriceNear(sw[4].price, sw[0].price)) return false;

   // 确认回调: 当前价格低于颈线
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(curPrice > sw[1].price) return false;

   neckline = (sw[3].price + sw[1].price) / 2.0;
   swingLowPrice = sw[2].price;  // 头部最低点

   return true;
}

//+------------------------------------------------------------------+
//| 检测头肩顶                                                         |
//|                                                                  |
//|  模式: 高点(左肩) → 低点 → 高点(头,更高) → 低点 → 高点(右肩)       |
//+------------------------------------------------------------------+
bool DetectHeadShoulders(double &neckline, double &swingHighPrice)
{
   if(g_swingCount < 5) return false;

   SwingPoint sw[6];
   int n = GetRecentSwings(sw, 6);
   if(n < 5) return false;

   // 模式: 高 → 低 → 高 → 低 → 高
   if(sw[4].type != 1 || sw[3].type != -1 || sw[2].type != 1 ||
      sw[1].type != -1 || sw[0].type != 1)
      return false;

   // 头(sw[2])必须高于左肩(sw[4])和右肩(sw[0])
   if(sw[2].price <= sw[4].price) return false;
   if(sw[2].price <= sw[0].price) return false;

   // 两个回调低点接近
   if(!PriceNear(sw[3].price, sw[1].price)) return false;

   // 左右肩接近
   if(!PriceNear(sw[4].price, sw[0].price)) return false;

   // 确认反弹: 当前价格高于颈线
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(curPrice < sw[1].price) return false;

   neckline = (sw[3].price + sw[1].price) / 2.0;
   swingHighPrice = sw[2].price;

   return true;
}

//+------------------------------------------------------------------+
//| 检测123法则(多头)                                                  |
//|                                                                  |
//|  在多头趋势的回调中:                                               |
//|    1. 找到回调低点                                                 |
//|    2. 反弹高点(不创新高)                                           |
//|    3. 二次回踩不破前低(更高低点)                                    |
//|  颈线 = 反弹高点                                                   |
//+------------------------------------------------------------------+
bool Detect123Bullish(double &neckline)
{
   if(g_swingCount < 3) return false;

   SwingPoint sw[5];
   int n = GetRecentSwings(sw, 5);
   if(n < 3) return false;

   // 找最近3个点: 低 → 高 → 低(更高)
   if(sw[2].type != -1 || sw[1].type != 1 || sw[0].type != -1)
      return false;

   // 反弹幅度足够
   if((sw[1].price - sw[2].price) < InpSwingMinPts * g_pt) return false;

   // 第二次低点高于第一次低点(不创新低)
   if(sw[0].price <= sw[2].price) return false;

   // 确认当前价格在回调区域
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(curPrice > sw[1].price) return false;

   neckline = sw[1].price;
   return true;
}

//+------------------------------------------------------------------+
//| 检测123法则(空头)                                                  |
//+------------------------------------------------------------------+
bool Detect123Bearish(double &neckline)
{
   if(g_swingCount < 3) return false;

   SwingPoint sw[5];
   int n = GetRecentSwings(sw, 5);
   if(n < 3) return false;

   // 找最近3个点: 高 → 低 → 高(更低)
   if(sw[2].type != 1 || sw[1].type != -1 || sw[0].type != 1)
      return false;

   if((sw[2].price - sw[1].price) < InpSwingMinPts * g_pt) return false;

   if(sw[0].price >= sw[2].price) return false;

   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(curPrice < sw[1].price) return false;

   neckline = sw[1].price;
   return true;
}

//+------------------------------------------------------------------+
//| 扫描所有形态并注册                                                 |
//|  根据当前趋势方向,只扫描对应方向的形态                              |
//+------------------------------------------------------------------+
void ScanPatterns()
{
   //--- 先清理过期形态
   CleanExpiredPatterns();

   datetime now = iTime(_Symbol, PERIOD_M1, 0);
   if(now == 0) return;

   double neckline = 0, dummy = 0;
   bool found = false;
   int pType = -1;

   //--- 多头趋势: 扫描 W底 / 头肩底 / 123多头
   if(g_trend == TREND_BULL)
   {
      if(DetectWBottom(neckline, dummy))
      {
         found = true;
         pType = 0; // W底
         Print("📐 检测到 W底 形态! 颈线=", DoubleToString(neckline, g_dig));
      }
      else if(DetectInvHeadShoulders(neckline, dummy))
      {
         found = true;
         pType = 2; // 头肩底
         Print("📐 检测到 头肩底 形态! 颈线=", DoubleToString(neckline, g_dig));
      }
      else if(Detect123Bullish(neckline))
      {
         found = true;
         pType = 4; // 123多头
         Print("📐 检测到 123多头 形态! 颈线=", DoubleToString(neckline, g_dig));
      }
   }
   //--- 空头趋势: 扫描 M顶 / 头肩顶 / 123空头
   else if(g_trend == TREND_BEAR)
   {
      if(DetectMTop(neckline, dummy))
      {
         found = true;
         pType = 1; // M顶
         Print("📐 检测到 M顶 形态! 颈线=", DoubleToString(neckline, g_dig));
      }
      else if(DetectHeadShoulders(neckline, dummy))
      {
         found = true;
         pType = 3; // 头肩顶
         Print("📐 检测到 头肩顶 形态! 颈线=", DoubleToString(neckline, g_dig));
      }
      else if(Detect123Bearish(neckline))
      {
         found = true;
         pType = 5; // 123空头
         Print("📐 检测到 123空头 形态! 颈线=", DoubleToString(neckline, g_dig));
      }
   }

   //--- 注册新形态
   if(found && g_patCount < 5)
   {
      g_patterns[g_patCount].patType   = pType;
      g_patterns[g_patCount].neckline  = neckline;
      g_patterns[g_patCount].formTime  = now;
      g_patterns[g_patCount].expireTime = now + InpPatternExpire * 60; // 1M每根60秒
      g_patterns[g_patCount].active    = true;
      g_patCount++;
   }
}

//+------------------------------------------------------------------+
//| 清理过期形态                                                       |
//+------------------------------------------------------------------+
void CleanExpiredPatterns()
{
   datetime now = iTime(_Symbol, PERIOD_M1, 0);
   if(now == 0) return;
   int newCount = 0;
   for(int i = 0; i < g_patCount; i++)
   {
      if(g_patterns[i].active && now < g_patterns[i].expireTime)
      {
         g_patterns[newCount] = g_patterns[i];
         newCount++;
      }
   }
   g_patCount = newCount;
}

//+------------------------------------------------------------------+
//| 清除所有形态(趋势反转时调用)                                        |
//+------------------------------------------------------------------+
void ClearPatterns()
{
   for(int i = 0; i < 5; i++)
      g_patterns[i].active = false;
   g_patCount = 0;
   g_entryPending = false;
   Print("🧹 趋势反转,清除所有活跃形态");
}

//+==================================================================+
//| 模块4: K线处理与入场                                              |
//+==================================================================+

//+------------------------------------------------------------------+
//| 处理每根新K线                                                      |
//|  检测新K线到来 → 更新趋势 + 扫描摆动点 + 扫描形态                  |
//+------------------------------------------------------------------+
void ProcessBar()
{
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == 0) return;

   //--- 新K线到来(或首次运行)
   if(curBar != g_lastBar || g_firstRun)
   {
      g_lastBar = curBar;
      g_firstRun = false;

      //--- 更新趋势
      UpdateTrend();

      //--- 无趋势则跳过后续处理
      if(g_trend == TREND_NONE)
      {
         ClearPatterns();
         return;
      }

      //--- 扫描摆动点
      ScanSwings();

      //--- 诊断日志(每5分钟)
      if(g_lastDiagLog != curBar && (curBar % 300) == 0)
      {
         g_lastDiagLog = curBar;
         Print("📋 诊断: 趋势=", (g_trend == TREND_BULL ? "多头" : "空头"),
               " 摆动点=", g_swingCount,
               " 活跃形态=", g_patCount,
               " 待入场=", (g_entryPending ? "是" : "否"));
      }

      //--- 扫描形态(新K线时)
      ScanPatterns();

      //--- 检查颈线突破(上一根已完成K线)
      CheckNecklineBreak();
   }
}

//+------------------------------------------------------------------+
//| 检查颈线突破                                                       |
//|  用上一根已完成K线(索引1)的收盘价检测                                |
//+------------------------------------------------------------------+
void CheckNecklineBreak()
{
   if(g_patCount == 0 || g_entryPending) return;

   double closePrev = iClose(_Symbol, PERIOD_M1, 1);
   if(closePrev <= 0) return;

   datetime barTime = iTime(_Symbol, PERIOD_M1, 1);
   if(barTime == 0) return;

   for(int i = 0; i < g_patCount; i++)
   {
      if(!g_patterns[i].active) continue;

      int pType = g_patterns[i].patType;
      double nk = g_patterns[i].neckline;

      //--- W底(0) / 头肩底(2) / 123多头(4): 收盘价 > 颈线
      if(pType == 0 || pType == 2 || pType == 4)
      {
         if(closePrev > nk)
         {
            static const string names[6] = {"W底", "M顶", "头肩底", "头肩顶", "123多头", "123空头"};
            Print("🎯 ", names[pType], "颈线突破! 颈线=", DoubleToString(nk, g_dig),
                  " 收盘=", DoubleToString(closePrev, g_dig),
                  " → 下根K线开盘入场做多");
            g_entryPending  = true;
            g_entryDir      = 1;
            g_entryNeckline = nk;
            g_breakBar      = barTime;
            // 清除此形态
            g_patterns[i].active = false;
            return;
         }
      }
      //--- M顶(1) / 头肩顶(3) / 123空头(5): 收盘价 < 颈线
      else if(pType == 1 || pType == 3 || pType == 5)
      {
         if(closePrev < nk)
         {
            static const string names[6] = {"W底", "M顶", "头肩底", "头肩顶", "123多头", "123空头"};
            Print("🎯 ", names[pType], "颈线突破! 颈线=", DoubleToString(nk, g_dig),
                  " 收盘=", DoubleToString(closePrev, g_dig),
                  " → 下根K线开盘入场做空");
            g_entryPending  = true;
            g_entryDir      = -1;
            g_entryNeckline = nk;
            g_breakBar      = barTime;
            g_patterns[i].active = false;
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 检查入场条件                                                       |
//|  颈线已突破,在下根K线(first tick)入场                              |
//+------------------------------------------------------------------+
void CheckEntry()
{
   if(!g_entryPending) return;

   //--- 确认已进入新K线(破颈线的K线已完成)
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == 0) return;

   // 破颈线的那根K线已经完成,当前是新K线
   // g_breakBar记录的是破颈线那根K线的时间
   // 当前K线时间 > g_breakBar 说明已经进入新K线
   if(curBar <= g_breakBar) return;  // 还在同一根K线内,等待

   //--- 双重确认: 破颈线的那根K线必须是已完成K线
   if(iTime(_Symbol, PERIOD_M1, 1) != g_breakBar) return;

   //--- 保证金检查
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0)
   {
      Print("⚠️ 可用保证金不足,放弃本次入场");
      g_entryPending = false;
      return;
   }

   //--- 计算手数
   double lot = CalcLot();
   if(lot <= 0)
   {
      g_entryPending = false;
      return;
   }

   //--- 执行入场
   if(g_entryDir == 1)
   {
      OpenBuy(lot);
   }
   else if(g_entryDir == -1)
   {
      OpenSell(lot);
   }

   g_entryPending = false;
}

//+==================================================================+
//| 模块5: 开仓                                                        |
//+==================================================================+

//+------------------------------------------------------------------+
//| 开多单                                                            |
//|  SL = 颈线 - 300点 | TP = 入场价 + 1200点                        |
//+------------------------------------------------------------------+
void OpenBuy(double lot)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = NormalizeDouble(g_entryNeckline - InpStopLossPts * g_pt, g_dig);
   double tp  = NormalizeDouble(ask + InpTakeProfitPts * g_pt, g_dig);

   //--- 修正SL/TP以满足最小距离
   FixSLTP(ask, true, sl, tp);

   //--- 有效性校验
   if(sl >= ask)
   {
      Print("❌ 多单SL无效: sl=", sl, " ask=", ask);
      return;
   }
   if(tp <= ask)
   {
      Print("❌ 多单TP无效: tp=", tp, " ask=", ask);
      return;
   }

   if(m_trade.Buy(lot, _Symbol, ask, sl, tp, "形态共振-多"))
   {
      Print("✅ 多单开仓成功  Lot=", DoubleToString(lot, 2),
            " 入场=", DoubleToString(ask, g_dig),
            " SL=", DoubleToString(sl, g_dig),
            " (颈线=", DoubleToString(g_entryNeckline, g_dig), "↓",
            DoubleToString(InpStopLossPts*10, 0), "美分)",
            " TP=", DoubleToString(tp, g_dig));
   }
   else
   {
      Print("❌ 多单开仓失败: ", m_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| 开空单                                                            |
//|  SL = 颈线 + 300点 | TP = 入场价 - 1200点                        |
//+------------------------------------------------------------------+
void OpenSell(double lot)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = NormalizeDouble(g_entryNeckline + InpStopLossPts * g_pt, g_dig);
   double tp  = NormalizeDouble(bid - InpTakeProfitPts * g_pt, g_dig);

   //--- 修正SL/TP
   FixSLTP(bid, false, sl, tp);

   if(sl <= bid)
   {
      Print("❌ 空单SL无效: sl=", sl, " bid=", bid);
      return;
   }
   if(tp >= bid)
   {
      Print("❌ 空单TP无效: tp=", tp, " bid=", bid);
      return;
   }

   if(m_trade.Sell(lot, _Symbol, bid, sl, tp, "形态共振-空"))
   {
      Print("✅ 空单开仓成功  Lot=", DoubleToString(lot, 2),
            " 入场=", DoubleToString(bid, g_dig),
            " SL=", DoubleToString(sl, g_dig),
            " (颈线=", DoubleToString(g_entryNeckline, g_dig), "↑",
            DoubleToString(InpStopLossPts*10, 0), "美分)",
            " TP=", DoubleToString(tp, g_dig));
   }
   else
   {
      Print("❌ 空单开仓失败: ", m_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| 修正SL/TP满足最小距离                                              |
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

//+==================================================================+
//| 模块6: 仓位管理                                                    |
//+==================================================================+

//+------------------------------------------------------------------+
//| 计算手数                                                           |
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
         Print("⚠️ 余额异常,使用固定手数: ", InpFixedLot);
         return InpFixedLot;
      }

      double riskMoney = balance * InpRiskPercent / 100.0;

      double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickValue <= 0 || tickSize <= 0)
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

      double lossPerLot = InpStopLossPts * pointValue;
      if(lossPerLot <= 0)
      {
         Print("⚠️ 每手亏损异常,使用固定手数: ", InpFixedLot);
         return InpFixedLot;
      }

      lot = riskMoney / lossPerLot;
   }

   //--- 规范化
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

   //--- 保证金校验(百分比模式)
   if(!InpUseFixedLot && lot > 0)
   {
      double marginFree = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double marginReq  = 0;
      if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq))
      {
         if(marginReq >= marginFree)
         {
            Print("⚠️ 保证金不足,自动降仓");
            double safeLot = marginFree * 0.9 / (marginReq / lot);
            safeLot = MathFloor(safeLot / step) * step;
            lot = MathMax(safeLot, finalMin);
            lot = MathMin(lot, finalMax);
         }
      }
   }

   return lot;
}

//+==================================================================+
//| 模块7: 追踪止损                                                    |
//|                                                                  |
//|  规则:                                                            |
//|    200点利润 → 激活追踪                                            |
//|    500点利润 → SL到达开仓位(保本)                                  |
//|  多单新SL = 当前Bid - 500点                                       |
//|  空单新SL = 当前Ask + 500点                                       |
//+==================================================================+

void CheckTrail()
{
   if(!InpUseTrailing) return;

   ulong ticket = GetMyPosTicket();
   if(ticket == 0) { g_trailRetries = 0; return; }

   //--- 冷却防高频
   if(ticket == g_trailTicket && g_trailRetries > 5) return;
   if(ticket == g_trailTicket && g_trailTime > 0)
   {
      if((TimeCurrent() - g_trailTime) * 1000 < InpTrailCooldownMs)
         return;
   }

   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currSL    = PositionGetDouble(POSITION_SL);
   double currTP    = PositionGetDouble(POSITION_TP);
   bool   modified  = false;

   if(posType == POSITION_TYPE_BUY)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profitPts = (bid - openPrice) / g_pt;

      if(profitPts >= InpTrailActivate)
      {
         double newSL = NormalizeDouble(bid - InpTrailDistance * g_pt, g_dig);

         // 新SL必须高于当前SL(只上移不后退)
         if(newSL > currSL)
         {
            if(m_trade.PositionModify(ticket, newSL, currTP))
            {
               Print("📈 多单追踪: 利润=", DoubleToString(profitPts, 0),
                     "点 SL:", DoubleToString(currSL, g_dig),
                     "→", DoubleToString(newSL, g_dig),
                     (newSL >= openPrice ? " [保本]" : ""));
               g_trailTicket  = ticket;
               g_trailTime    = TimeCurrent();
               g_trailRetries = 0;
               modified = true;
            }
            else
            {
               g_trailRetries++;
               g_trailTime = TimeCurrent();
            }
         }
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (openPrice - ask) / g_pt;

      if(profitPts >= InpTrailActivate)
      {
         double newSL = NormalizeDouble(ask + InpTrailDistance * g_pt, g_dig);

         bool slValid = (currSL == 0) || (newSL < currSL);
         if(slValid)
         {
            if(m_trade.PositionModify(ticket, newSL, currTP))
            {
               Print("📉 空单追踪: 利润=", DoubleToString(profitPts, 0),
                     "点 SL:", DoubleToString(currSL, g_dig),
                     "→", DoubleToString(newSL, g_dig),
                     (newSL <= openPrice ? " [保本]" : ""));
               g_trailTicket  = ticket;
               g_trailTime    = TimeCurrent();
               g_trailRetries = 0;
               modified = true;
            }
            else
            {
               g_trailRetries++;
               g_trailTime = TimeCurrent();
            }
         }
      }
   }

   if(!modified && ticket == g_trailTicket)
      g_trailTime = TimeCurrent();
}

//+==================================================================+
//| 模块8: 风控与辅助                                                  |
//+==================================================================+

//+------------------------------------------------------------------+
//| 交易时间检查(北京时间)                                              |
//+------------------------------------------------------------------+
bool IsTradeTime()
{
   datetime bjTime = TimeCurrent() + g_bjOffset;
   MqlDateTime dt;
   if(!TimeToStruct(bjTime, dt)) return false;

   int curMin = dt.hour * 60 + dt.min;

   int sHour = 7, sMin = 30, eHour = 3, eMin = 30;

   if(StringLen(InpStartTime) >= 5)
   {
      string parts[2];
      if(StringSplit(InpStartTime, ':', parts) == 2)
      {
         sHour = MathMax(0, MathMin(23, (int)StringToInteger(parts[0])));
         sMin  = MathMax(0, MathMin(59, (int)StringToInteger(parts[1])));
      }
   }
   if(StringLen(InpEndTime) >= 5)
   {
      string parts[2];
      if(StringSplit(InpEndTime, ':', parts) == 2)
      {
         eHour = MathMax(0, MathMin(23, (int)StringToInteger(parts[0])));
         eMin  = MathMax(0, MathMin(59, (int)StringToInteger(parts[1])));
      }
   }

   int startMin = sHour * 60 + sMin;
   int endMin   = eHour * 60 + eMin;

   if(startMin <= endMin)
      return (curMin >= startMin && curMin <= endMin);
   else
      return (curMin >= startMin || curMin <= endMin);
}

//+------------------------------------------------------------------+
//| 每日更新                                                           |
//+------------------------------------------------------------------+
void UpdateDay()
{
   datetime bjTime = TimeCurrent() + g_bjOffset;
   MqlDateTime dt;
   if(!TimeToStruct(bjTime, dt)) return;

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
   }
}

//+------------------------------------------------------------------+
//| 重置每日风控                                                       |
//+------------------------------------------------------------------+
void ResetDay()
{
   datetime bjTime = TimeCurrent() + g_bjOffset;
   MqlDateTime dt;
   if(!TimeToStruct(bjTime, dt)) return;

   g_dayNum   = dt.day_of_year;
   g_dayBal   = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayLimit = false;
   g_trailRetries = 0;
   g_trailTicket  = 0;
   g_entryPending = false;
   ClearPatterns();

   Print("📅 新交易日初始化 余额=", DoubleToString(g_dayBal, 2));
}

//+------------------------------------------------------------------+
//| 当日最大亏损检查                                                    |
//+------------------------------------------------------------------+
bool CheckDayLoss()
{
   if(g_dayLimit) return false;
   if(!InpUseDailyLoss) return true;

   double curBal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(curBal > g_dayBal)
   {
      g_dayBal = curBal;
      return true;
   }

   double lossPct = (g_dayBal - curBal) / g_dayBal * 100.0;
   if(lossPct >= InpDailyLossPct)
   {
      g_dayLimit = true;
      Print("⚠️ 风控触发: 当日亏损已达 ", DoubleToString(lossPct, 1),
            "%, 超过 ", DoubleToString(InpDailyLossPct, 1), "% 限制");
      Print("   今日禁止开新仓,仅执行追踪止损");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 点差检查                                                           |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   if(!InpUseSpreadLimit) return true;

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
   {
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 是否有本EA持仓                                                      |
//+------------------------------------------------------------------+
bool HasMyPos()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 获取本EA持仓ticket                                                 |
//+------------------------------------------------------------------+
ulong GetMyPosTicket()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return ticket;
   }
   return 0;
}
//+------------------------------------------------------------------+
