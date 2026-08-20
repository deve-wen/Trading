//+------------------------------------------------------------------+
//|                        顺势突破策略.mq5                              |
//|                                                                   |
//|  趋势: EMA55/MA233金叉=多头(只做多) 死叉=空头(只做空)             |
//|       与戴维策略/金刚经系列趋势定义完全一致                          |
//|  周期: 黄金 M1                                                      |
//|                                                                   |
//|  ★ 入场方式(只有这一种): 顺势突破关键位                            |
//|    - 找最近的关键K线(摆动点): 做空→SwingLow最低价, 做多→SwingHigh最高价|
//|    - 有效突破: 盘中突破关键位 + 收盘收在关键位另一侧                 |
//|        做空: bar1.Low<关键低点 AND bar1.Close<关键低点              |
//|        做多: bar1.High>关键高点 AND bar1.Close>关键高点             |
//|    - 入场: 下一根K线开盘市价                                       |
//|    - 一个顺势突破信号只开一次仓(iTime时间戳去重)                    |
//|    - 多头完全镜像                                                  |
//|                                                                   |
//|  止损: 该波段起点摆动点±20点 (做空: 该下跌波段最高点+20, 做多: 该上涨波段最低点-20) |
//|  止盈: 固定盈亏比 2.6:1 (TP = 入场价 ± 2.6×SL区间)                  |
//|         "该波段"=突破关键位之前最近的摆动点起到关键位为止的一段行情   |
//|                                                                   |
//|  风控: 止损≥1500点拒开; 追踪A/B/C三选一; 日亏限; 点差; 连续亏暂停 |
//|  收盘: ★不持仓过夜: 收盘前N分钟强平; 收盘前30分钟禁开新仓         |
//+------------------------------------------------------------------+
#property copyright "Senior Developer"
#property version   "1.17"
#property description "顺势突破策略: EMA55/MA233顺势 + 唯一入场=顺势突破关键位"
#property description "① 趋势: EMA55/MA233金叉死叉只做顺势(与戴维/金刚经系列一致)"
#property description "② 入场(唯一): 顺势突破关键位=盘中突破+收盘站另一侧→下根K线开盘市价"
#property description "③ 止损: 该波段起点摆动点±20点; 止盈: 固定盈亏比2.6:1"
#property description "④ 一个顺势突破信号只开一次仓(双重去重: 同bar1+同关键位)"
#property description "⑤ 风控: 止损≥1500点拒开; 追踪A/B/C三选一; 收盘强平+禁开仓"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ⚠️ MQL5 黄金法则: input 必须在此处 (#include 模块之前) 声明        |
//+------------------------------------------------------------------+

//=== ★ 交易时间(北京时间) ===
input int    InpServerHourDiff     = 5;      // 服务器比北京晚N小时(MT5=5) ← 仅 InpAutoDetectServerTZ=false 时生效
input bool   InpAutoDetectServerTZ = true;   // ★v1.10: 自动检测服务器时区(推荐, 消除多终端时区差异; 需电脑本地时区正确)
input int    InpTradeStartHour     = 7;      // 交易开始 时(北京)
input int    InpTradeStartMinute   = 30;     // 交易开始 分(北京)
input int    InpTradeEndHour       = 3;      // 交易结束 时(北京次日)
input int    InpTradeEndMinute     = 30;     // 交易结束 分(北京次日)

//=== ★ 收盘强平与禁开仓(不持仓过夜) ===
input bool   InpUseEndCloseAll     = true;   // ★启用收盘强平(交易结束前N分钟强平全部持仓, 不论盈亏)
input int    InpCloseAllMinsBeforeEnd = 2;   // 强平提前量: 距交易结束≤此分钟数时强平所有持仓(默认2分钟)
input int    InpNoEntryMinsBeforeEnd  = 30;  // 禁开仓提前量: 距交易结束≤此分钟数时禁止开新仓(默认30分钟)

//=== ★ 诊断日志 ===
input bool   InpDiagnosticLog      = false;  // ★详细诊断日志(开仓拦截原因+环境信息, 排查不一致时开启)

//=== ★ 仓位管理 ===
input bool   InpUseFixedLot        = true;   // true=固定手数 false=百分比
input double InpFixedLot           = 0.01;   // 固定手数
input double InpRiskPercent        = 1.0;    // 风险百分比(%)
input double InpMinLot             = 0.01;   // 最小手数
input double InpMaxLot             = 10.0;   // 最大手数

//=== ★ 止损止盈开关 ===
input bool   InpUseFixedStopLoss   = true;   // 启用固定止损(顺势突破强制true: 关键位SL必带)
input bool   InpUseFixedTakeProfit = true;   // 启用固定止盈(顺势突破强制true: 2.6:1 TP必带)

//=== ★ 止损与追踪(共用基础参数) ===
input int    InpFixedSLPoints      = 300;    // 固定止损点数(策略不依赖此值, 关键位SL动态计算)
input int    InpFixedTPPoints      = 660;    // 固定止盈点数(策略不依赖此值, 2.6:1 TP动态计算)

//=== ★ 追踪方式A: 渐进式(持续追踪SL,二选一) ===
input bool   InpUseTrailingA       = false;  // 启用追踪A(与B互斥)
input int    InpTrailingAActivatePts = 20;   // A: 追踪激活利润点数
input int    InpTrailingABreakEvenPts = 320; // A: 保本点数(SL移入场价)

//=== ★ 追踪方式B: 一次性保本(触发后锁死,二选一) ===
input bool   InpUseTrailingB       = true;   // 启用追踪B(与A/C互斥)
input int    InpTrailingBTriggerPts  = 320;  // B: 触发保本的利润点数
input int    InpTrailingBProtectPts  = 20;   // B: 保护利润(SL移开仓±此点数)

//=== ★ 追踪方式C: 形态追踪止损(三选一, 与A/B互斥) ===
input bool   InpUseTrailingC          = false;  // 启用追踪C(与A/B互斥) ← 勾选即用C
input bool   InpTrailingCUsePatternOnly = false; // C: true=跳过触发阶段直接形态追踪(默认false=先锁55点再形态)
input int    InpTrailingCTriggerPts   = 300;  // C: 触发保本的利润点数(如300)
input int    InpTrailingCProtectPts   = 55;   // C: 触发后保护利润(SL移开仓±此点数,如55)
input int    InpTrailingCSLBufferPts  = 20;   // C: 形态偏移(支撑下/压力上N点)
input int    InpTrailingCLookbackBars = 60;   // C: 支撑/压力识别回看K线数(参照金刚经60)

//=== ★ 风控管理 ===
input bool   InpUseDailyLossLimit  = true;   // 启用当日最大亏损限制
input double InpDailyLossPercent   = 5.0;    // 当日最大亏损(%)
input bool   InpUseSpreadLimit     = true;   // 启用点差限制
input int    InpMaxSpreadPoints    = 50;     // 最大允许点差

//=== ★ 连续亏损暂停 ===
input bool   InpUseConsecutiveLossPause = false; // 启用连续亏损暂停
input int    InpConsecutiveLossCount  = 3;     // 连续亏损N次后暂停
input int    InpPauseMinutes        = 90;     // 暂停时间(分钟)

//+------------------------------------------------------------------+
//| ★顺势突破策略输入参数                                            |
//+------------------------------------------------------------------+
input group "=== ★ 顺势突破策略: 趋势判断(克罗: 顺势追市) ==="
input bool   InpUseTrendFilter     = true;    // 启用EMA55/MA233趋势判断(只做顺势, 推荐开)
input int    InpFastMAPeriod       = 55;      // 快线EMA周期(EMA55)
input ENUM_MA_METHOD InpFastMAMethod = MODE_EMA;  // 快线MA类型
input int    InpSlowMAPeriod       = 233;     // 慢线MA周期(MA233)
input ENUM_MA_METHOD InpSlowMAMethod = MODE_SMA;  // 慢线MA类型
input ENUM_APPLIED_PRICE InpMAApplied = PRICE_CLOSE; // MA应用价格
input ENUM_TIMEFRAMES InpTrendTF  = PERIOD_M1; // 趋势过滤周期

input group "=== ★ 顺势突破策略: 关键位识别(Swing关键K线) ==="
input ENUM_TIMEFRAMES InpPatternTF = PERIOD_M1; // 关键位识别周期
input int    InpSwingStrength      = 3;        // ★v1.17已弃用: 关键位/追踪C统一固定strength=2(参照追踪C定义), 此参数仅保留显示
input int    InpSwingLookback      = 40;       // 摆动点搜索回看K线数(找最近的摆动点: 突破关键位 + 该波段起点)

input group "=== ★ 顺势突破策略: 出场参数 ==="
input bool   InpUseRiskRewardRatio = true;    // ★v1.15固定盈亏比开关: true=SL按规则+TP=SL×盈亏比; false=固定SL300/TP660
input int    InpSLBufferPts        = 20;       // 关键位止损缓冲(点): SL=关键位±此点数
input double InpRewardRiskRatio    = 2.6;      // ★固定盈亏比(TP/SL倍数): 2.6=2.6:1

input group "=== ★ 顺势突破策略: 风控(单信号只开一次) ==="
input bool   InpUseMaxSLPoints     = true;     // 启用最大止损限制(止损过大不开仓)
input int    InpMaxSLPoints        = 1500;     // 最大允许止损点数(默认1500点=15美金)
input int    InpMaxPositions       = 1;        // 最大同时持仓数(顺势突破一个信号只开一次, 推荐1)

//+------------------------------------------------------------------+
//| 通用交易模块 (input 已按黄金法则在主文件声明)                      |
//| ★ 自包含: 通用模块代码已嵌入本EA, 单文件即可编译                   |
//|    用户只需复制此 .mq5 文件即可, 无需再复制 .mqh 模块文件        |
//+------------------------------------------------------------------+

#ifndef C_COMMON_TRADING_MODULE_MQH
#define C_COMMON_TRADING_MODULE_MQH

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| 追踪槽位容量宏 (MQL5: 类内static const数组维度不受支持, 用宏)     |
//+------------------------------------------------------------------+
#define TRAIL_SLOT_COUNT 100

//+------------------------------------------------------------------+
//| 服务器时区偏移(小时, 相对GMT)                                     |
//+------------------------------------------------------------------+
int ServerTZOffsetHours()
{
   datetime server = TimeCurrent();
   datetime gmt    = TimeGMT();
   return (int)MathRound((server - gmt) / 3600.0);
}

//+------------------------------------------------------------------+
//| 当前北京时间                                                      |
//+------------------------------------------------------------------+
datetime BeijingTimeNow()
{
   datetime server = TimeCurrent();
   if(InpAutoDetectServerTZ)
   {
      int serverTZ = ServerTZOffsetHours();
      return server + (8 - serverTZ) * 3600;
   }
   return server + InpServerHourDiff * 3600;
}

//+------------------------------------------------------------------+
//| 距交易结束还有多少分钟                                             |
//+------------------------------------------------------------------+
int MinutesToSessionEnd()
{
   datetime bj = BeijingTimeNow();
   MqlDateTime dt;
   TimeToStruct(bj, dt);

   datetime endToday = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",
                             dt.year, dt.mon, dt.day, InpTradeEndHour, InpTradeEndMinute));

   int minsToEnd = (int)((endToday - bj) / 60);
   if(minsToEnd < 0)
      minsToEnd += 1440;

   return minsToEnd;
}

//+------------------------------------------------------------------+
//| 通用交易模块类                                                      |
//+------------------------------------------------------------------+
class CCommonTradingModule
{
private:
   CTrade      m_trade;
   CPositionInfo m_positionInfo;
   COrderInfo  m_orderInfo;

   datetime    m_lastTradeDay;
   double      m_dailyLoss;
   int         m_consecutiveLoss;
   datetime    m_pauseUntil;
   datetime    m_lastHistoryCheck;

   ulong       m_trailTickets[TRAIL_SLOT_COUNT];
   bool        m_trailSlotUsed[TRAIL_SLOT_COUNT];
   int         m_trailNextIdx;

   bool        IsNewTradingDay();
   int         FindOrCreateTrailSlot(ulong ticket);
   void        PruneClosedTrailSlots();
   double      NormalizePrice(double price);
   int         NormalizePoints(int points);
   bool        SafeModifyPosition(ulong ticket, double newSL, double newTP, const string &ctx);
   void        OnDealProcessed(ulong ticket, double net);

   //--- 追踪A相关
   int         m_trailStage[TRAIL_SLOT_COUNT];

public:
   CCommonTradingModule();
   ~CCommonTradingModule();

   bool        Init(int magic, const string &commentPrefix);
   void        OnTick();
   void        OnTrade();
   void        OnTimer();
   bool        IsTradingAllowed();
   bool        IsTradeTimeAllowed();
   bool        CheckSpreadLimit();
   bool        CheckDailyLossLimit();
   bool        CheckConsecutiveLossPause();

   //--- 追踪互斥判断
   bool        IsTrailingAEnabled();
   bool        IsTrailingBEnabled();
   bool        IsTrailingCEnabled();

   //--- 开仓接口
   bool        OpenPosition(ENUM_ORDER_TYPE type, double price, double slPoints, double tpPoints);
   int         CountPositionsByMagic();

   //--- 仓位手数计算
   double      CalcLots(int slPoints);

   //--- 直接平仓接口
   bool        ClosePositionByComment(int magic, const string &commentMatch);
};

//+------------------------------------------------------------------+
CCommonTradingModule::CCommonTradingModule()
{
   ZeroMemory(m_trailTickets);
   ZeroMemory(m_trailSlotUsed);
   ZeroMemory(m_trailStage);
   m_trailNextIdx = 0;
   m_lastTradeDay = 0;
   m_dailyLoss = 0;
   m_consecutiveLoss = 0;
   m_pauseUntil = 0;
   m_lastHistoryCheck = 0;
}

//+------------------------------------------------------------------+
CCommonTradingModule::~CCommonTradingModule()
{
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::Init(int magic, const string &commentPrefix)
{
   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(50);
   m_trade.SetAsyncMode(false);
   // ★v1.01修复: 删除 SetTypeFilling(ORDER_FILLING_FOK)
   //   与戴维/金刚经系列一致, 使用CTrade默认填充模式
   //   部分broker黄金只支持IOC, FOK强制模式会导致市价单被拒

   ZeroMemory(m_trailTickets);
   ZeroMemory(m_trailSlotUsed);
   ZeroMemory(m_trailStage);

   Print("✅ CommonModule v4.13 初始化完成 | Magic=", magic, " Comment前缀=", commentPrefix);
   return true;
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::IsNewTradingDay()
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today != m_lastTradeDay)
   {
      m_lastTradeDay = today;
      m_dailyLoss = 0;
      Print("📅 新交易日, 重置日亏损累计 | 日期=", TimeToString(today, TIME_DATE));
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
int CCommonTradingModule::FindOrCreateTrailSlot(ulong ticket)
{
   PruneClosedTrailSlots();

   // 已存在 → 返回
   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      if(m_trailSlotUsed[i] && m_trailTickets[i] == ticket)
         return i;
   }
   // 不存在 → 分配新槽
   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      if(!m_trailSlotUsed[i])
      {
         m_trailTickets[i] = ticket;
         m_trailSlotUsed[i] = true;
         m_trailStage[i] = 0;
         return i;
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
void CCommonTradingModule::PruneClosedTrailSlots()
{
   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      if(!m_trailSlotUsed[i]) continue;
      bool exists = false;
      for(int j = PositionsTotal() - 1; j >= 0; j--)
      {
         ulong t = PositionGetTicket(j);
         if(t == m_trailTickets[i]) { exists = true; break; }
      }
      if(!exists)
      {
         m_trailSlotUsed[i] = false;
         m_trailTickets[i] = 0;
         m_trailStage[i] = 0;
      }
   }
}

//+------------------------------------------------------------------+
double CCommonTradingModule::NormalizePrice(double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      return NormalizeDouble(MathRound(price / tickSize) * tickSize, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
int CCommonTradingModule::NormalizePoints(int points)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return points * 10;
   return points;
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::SafeModifyPosition(ulong ticket, double newSL, double newTP, const string &ctx)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double currentTP = PositionGetDouble(POSITION_TP);
   // 若newTP未指定(<=0),用currentTP保持原TP不动
   double tpToUse = (newTP > 0) ? newTP : currentTP;
   if(!m_trade.PositionModify(ticket, newSL, tpToUse))
   {
      PrintFormat("❌ PositionModify FAILED [%s] ticket=%I64u retcode=%u (%s)",
                  ctx, ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void CCommonTradingModule::OnDealProcessed(ulong ticket, double net)
{
   if(net < 0)
   {
      m_dailyLoss += MathAbs(net);
      m_consecutiveLoss++;
      if(InpUseConsecutiveLossPause && m_consecutiveLoss >= InpConsecutiveLossCount)
         m_pauseUntil = TimeCurrent() + InpPauseMinutes * 60;
   }
   else
   {
      m_consecutiveLoss = 0;
   }
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTradeTimeAllowed()
{
   datetime bj = BeijingTimeNow();
   MqlDateTime dt;
   TimeToStruct(bj, dt);

   int startMin = InpTradeStartHour * 60 + InpTradeStartMinute;
   int endMin   = InpTradeEndHour   * 60 + InpTradeEndMinute;
   int curMin   = dt.hour * 60 + dt.min;

   if(startMin < endMin)
      return (curMin >= startMin && curMin < endMin);
   // 跨天: 7:30 ~ 次日3:30
   return (curMin >= startMin || curMin < endMin);
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::CheckSpreadLimit()
{
   if(!InpUseSpreadLimit) return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::CheckDailyLossLimit()
{
   if(!InpUseDailyLossLimit) return true;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double maxLoss = balance * InpDailyLossPercent / 100.0;
   return (m_dailyLoss < maxLoss);
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::CheckConsecutiveLossPause()
{
   if(!InpUseConsecutiveLossPause) return true;
   if(m_pauseUntil > 0 && TimeCurrent() < m_pauseUntil) return false;
   return true;
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTradingAllowed()
{
   IsNewTradingDay();
   if(!IsTradeTimeAllowed()) return false;
   if(!CheckSpreadLimit())   return false;
   if(!CheckDailyLossLimit()) return false;
   if(!CheckConsecutiveLossPause()) return false;
   // 收盘前禁开仓
   if(InpNoEntryMinsBeforeEnd > 0)
   {
      int minsToEnd = MinutesToSessionEnd();
      if(minsToEnd <= InpNoEntryMinsBeforeEnd) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTrailingAEnabled()
{
   int cnt = (InpUseTrailingA ? 1 : 0) + (InpUseTrailingB ? 1 : 0) + (InpUseTrailingC ? 1 : 0);
   if(cnt > 1)
   {
      static bool warned = false;
      if(!warned)
      {
         Print("⚠️ 追踪A/B/C多个同时启用, 优先级 A>B>C 生效 (仅执行优先级最高者)");
         warned = true;
      }
   }
   if(InpUseTrailingA) return true;
   return false;
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTrailingBEnabled()
{
   if(InpUseTrailingA) return false;
   if(InpUseTrailingB) return true;
   return false;
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTrailingCEnabled()
{
   if(InpUseTrailingA) return false;
   if(InpUseTrailingB) return false;
   if(InpUseTrailingC) return true;
   return false;
}

//+------------------------------------------------------------------+
double CCommonTradingModule::CalcLots(int slPoints)
{
   if(InpUseFixedLot)
      return NormalizeLot(InpFixedLot);

   // 百分比手数计算
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0 || slPoints <= 0)
      return NormalizeLot(InpMinLot);

   double slMoneyPerLot = (slPoints * _Point / tickSize) * tickValue;
   if(slMoneyPerLot <= 0)
      return NormalizeLot(InpMinLot);

   double lots = riskMoney / slMoneyPerLot;
   return NormalizeLot(lots);
}

//+------------------------------------------------------------------+
int CCommonTradingModule::CountPositionsByMagic()
{
   int count = 0;
   long magic = m_trade.RequestMagic();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::OpenPosition(ENUM_ORDER_TYPE type, double price, double slPoints, double tpPoints)
{
   // 1. 风控检查
   if(!IsTradingAllowed()) return false;

   // 2. 手数计算
   double lots = CalcLots((int)slPoints);
   if(lots <= 0) return false;

   // 3. SL/TP价格
   double slPrice = 0, tpPrice = 0;
   if(InpUseFixedStopLoss && slPoints > 0)
   {
      slPrice = NormalizePrice((type == ORDER_TYPE_BUY)
                               ? price - slPoints * _Point
                               : price + slPoints * _Point);
   }
   if(InpUseFixedTakeProfit && tpPoints > 0)
   {
      tpPrice = NormalizePrice((type == ORDER_TYPE_BUY)
                               ? price + tpPoints * _Point
                               : price - tpPoints * _Point);
   }

   // 4. 发送订单
   string comment = IntegerToString(m_trade.RequestMagic()) + "_SBTD";
   if(!m_trade.PositionOpen(_Symbol, type, lots, price, slPrice, tpPrice, comment))
   {
      PrintFormat("❌ OpenPosition FAILED type=%d lots=%.2f price=%.2f retcode=%u (%s)",
                  type, lots, price, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
      return false;
   }

   ulong ticket = m_trade.ResultOrder();
   Print("✅ 开仓成功 ticket=", ticket, " type=", EnumToString(type),
         " lots=", lots, " price=", price, " SL=", slPrice, " TP=", tpPrice);
   return true;
}

//+------------------------------------------------------------------+
bool CCommonTradingModule::ClosePositionByComment(int magic, const string &commentMatch)
{
   bool any = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      string c = PositionGetString(POSITION_COMMENT);
      if(StringFind(c, commentMatch) >= 0)
      {
         if(m_trade.PositionClose(ticket)) any = true;
      }
   }
   return any;
}

//+------------------------------------------------------------------+
//| 追踪止损核心 (三种模式: A渐进 / B一次性 / C形态)                   |
//+------------------------------------------------------------------+
void CCommonTradingModule::OnTick()
{
   // 清理已平仓槽位
   PruneClosedTrailSlots();

   bool aOn = IsTrailingAEnabled();
   bool bOn = IsTrailingBEnabled();
   bool cOn = IsTrailingCEnabled();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != m_trade.RequestMagic()) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      double curPrice  = (ptype == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitPts = (ptype == POSITION_TYPE_BUY)
                         ? (curPrice - openPrice) / _Point
                         : (openPrice - curPrice) / _Point;

      int slot = FindOrCreateTrailSlot(ticket);
      if(slot < 0) continue;

      // ===== 追踪A: 渐进式 =====
      if(aOn)
      {
         // Phase 1: 利润 ≥ 保本点数 → SL移入场价
         // ★v1.01修复: 即使SL已在入场价(无需移动), 也标记stage=1进入Phase2
         //   旧逻辑: needMove=false时stage不更新 → 永远卡在Phase1, 渐进追踪永不生效
         if(profitPts >= InpTrailingABreakEvenPts && m_trailStage[slot] < 1)
         {
            double newSL = NormalizePrice(openPrice);
            bool needMove = false;
            if(ptype == POSITION_TYPE_BUY)
               needMove = (curSL == 0 || newSL > curSL + _Point);
            else
               needMove = (curSL == 0 || newSL < curSL - _Point);
            if(needMove)
            {
               if(SafeModifyPosition(ticket, newSL, curTP, "TrailingA.Phase1"))
                  Print("🔵 [TrailingA.Phase1] ticket=", ticket, " SL→入场价 ", newSL);
            }
            m_trailStage[slot] = 1;   // ★v1.01 无条件进入Phase2
         }
         // Phase 2: 利润 ≥ 激活点数 → SL持续贴近当前价
         else if(profitPts >= InpTrailingAActivatePts && m_trailStage[slot] == 1)
         {
            int stepPts = InpTrailingAActivatePts;
            double newSL = NormalizePrice((ptype == POSITION_TYPE_BUY)
                                          ? curPrice - stepPts * _Point
                                          : curPrice + stepPts * _Point);
            bool needMove = false;
            if(ptype == POSITION_TYPE_BUY)
               needMove = (curSL == 0 || newSL > curSL + _Point);
            else
               needMove = (curSL == 0 || newSL < curSL - _Point);
            if(needMove)
            {
               if(SafeModifyPosition(ticket, newSL, curTP, "TrailingA.Phase2"))
                  Print("🔵 [TrailingA.Phase2] ticket=", ticket, " SL→", newSL, " 利润=", profitPts, "点");
            }
         }
      }
      // ===== 追踪B: 一次性保本 =====
      else if(bOn)
      {
         // ★v1.01修复: 同A, 满足触发即标记锁死(防止SL已到位时反复空转)
         if(profitPts >= InpTrailingBTriggerPts && m_trailStage[slot] == 0)
         {
            double newSL = NormalizePrice((ptype == POSITION_TYPE_BUY)
                                          ? openPrice + InpTrailingBProtectPts * _Point
                                          : openPrice - InpTrailingBProtectPts * _Point);
            bool needMove = false;
            if(ptype == POSITION_TYPE_BUY)
               needMove = (curSL == 0 || newSL > curSL + _Point);
            else
               needMove = (curSL == 0 || newSL < curSL - _Point);
            if(needMove)
            {
               if(SafeModifyPosition(ticket, newSL, curTP, "TrailingB.OneShot"))
                  Print("🟢 [TrailingB.OneShot] ticket=", ticket, " SL→", newSL, " 利润=", profitPts, "点");
            }
            m_trailStage[slot] = 1;   // ★v1.01 一次性锁死, 不再重复检查
         }
      }
      // ===== 追踪C: 形态追踪(支撑/压力位) ★v1.10 严格三阶段 =====
      else if(cOn)
      {
         // --- Phase 1: 保本锁(可选, InpTrailingCUsePatternOnly=true 跳过) ---
         // ★v1.10 用户明确要求三阶段严格顺序:
         //   ① 利润 < 300点 → 止损线【完全不动】(保持初始位置)
         //   ② 利润 ≥ 300点 → 止损【直接跳到开仓价 ± 55点】锁定利润, 避免盈利变亏损
         //   ③ 之后 → 才根据形态(摆动点)逐步移动止损
         if(!InpTrailingCUsePatternOnly)
         {
            if(InpTrailingCTriggerPts <= 0 || InpTrailingCProtectPts <= 0)
            {
               Print("🟣 [TrailingC.Phase1] SKIP ticket=", ticket,
                     " (TriggerPts=", InpTrailingCTriggerPts,
                     " 或 ProtectPts=", InpTrailingCProtectPts, " 无效)");
               continue;
            }

            // ★v1.10修复: 利润未达触发点 → 止损完全不动(跳过Phase2, 避免提前追踪)
            if(profitPts < InpTrailingCTriggerPts)
            {
               if(InpDiagnosticLog)
                  Print("🟣 [TrailingC] 等待利润≥", InpTrailingCTriggerPts,
                        "点 (当前=", DoubleToString(profitPts, 1), "点) 止损不动 ticket=", ticket);
               continue;   // ★关键: 直接跳过本仓位, SL保持初始位置
            }

            // ★利润已达触发点 → Phase 1: 止损直接移到开仓价 ± 保护点数(锁利润)
            double lockSL = NormalizePrice((ptype == POSITION_TYPE_BUY)
                                           ? openPrice + InpTrailingCProtectPts * _Point
                                           : openPrice - InpTrailingCProtectPts * _Point);
            // 仅当当前SL比目标锁定位更差时才移动(BUY: currentSL < lockSL; SELL: currentSL > lockSL)
            bool needLock = false;
            if(ptype == POSITION_TYPE_BUY)
               needLock = (curSL == 0 || curSL < lockSL - _Point);
            else
               needLock = (curSL == 0 || curSL > lockSL + _Point);
            if(needLock)
            {
               if(SafeModifyPosition(ticket, lockSL, curTP, "TrailingC.Phase1"))
               {
                  curSL = lockSL;   // 刷新本地SL, 供Phase2基于正确基准判断
                  Print("🟣 [TrailingC.Phase1] ticket=", ticket, " SL→", lockSL,
                        " (锁", InpTrailingCProtectPts, "点利润)");
               }
            }
            // 锁完后同tick继续进入 Phase 2 形态追踪(此时profitPts已≥触发点)
         }

         // --- Phase 2: 形态追踪(摆动点支撑/压力位) ★v1.16参照金刚经规则 ---
         // ★v1.16关键修复: 形态追踪改用独立 strength=2 (金刚经规则"简化摆动强度,
         //   形态追踪用2根足够"), 不再用入场检测的 InpSwingStrength=3
         //   根因: 3根确认在快行情/浅回调时摆动点形成慢 → SL有时没跟上形态
         //   金刚经范式: 起点 i=strength+1=3, 找最近摆动点, 多头SL=摆动低点-缓冲
         //   ★v1.10: 非 pattern-only 模式下, 只有 profitPts ≥ 300 才可能走到这里
         //   (上面 continue 已拦截利润不足的情况); pattern-only 模式无条件执行
         {
            int swingStrength = 2;                       // ★v1.16 参照金刚经: 形态追踪2根确认足够
            int minGap = swingStrength + 1;              // = 3 (起点, 保证右翼确认)
            int trailLookback = (InpTrailingCLookbackBars > 0) ? InpTrailingCLookbackBars : 60;
            double keyLevel = 0;
            bool found = false;
            if(ptype == POSITION_TYPE_BUY)
            {
               int idx = FindSwingLow(minGap, trailLookback, swingStrength);
               if(idx > 0) { keyLevel = iLow(_Symbol, InpPatternTF, idx); found = true; }
            }
            else
            {
               int idx = FindSwingHigh(minGap, trailLookback, swingStrength);
               if(idx > 0) { keyLevel = iHigh(_Symbol, InpPatternTF, idx); found = true; }
            }
            if(found)
            {
               double newSL = NormalizePrice((ptype == POSITION_TYPE_BUY)
                                             ? keyLevel - InpTrailingCSLBufferPts * _Point
                                             : keyLevel + InpTrailingCSLBufferPts * _Point);
               // ★约束: 多头SL只能上移且须>当前SL; 空头SL只能下移且须<当前SL。
               //   摆动点须在当前SL"内侧"(多头摆动低点>当前SL / 空头摆动高点<当前SL)才采用,
               //   否则该摆动点比当前SL更靠外(历史极值), 不应回拉SL
               bool needMove = false;
               if(ptype == POSITION_TYPE_BUY)
                  needMove = (newSL > curSL + _Point);
               else
                  needMove = (newSL < curSL - _Point);
               if(needMove)
               {
                  if(SafeModifyPosition(ticket, newSL, curTP, "TrailingC.Phase2"))
                  {
                     curSL = newSL;   // 刷新本地SL, 下一tick基于新基准
                     Print("🟣 [TrailingC.Phase2] ticket=", ticket, " SL→", newSL, " 摆动位=", keyLevel);
                  }
               }
               else if(InpDiagnosticLog)
               {
                  Print("🟣 [TrailingC.Phase2] SKIP ticket=", ticket,
                        " 摆动位=", DoubleToString(keyLevel, 2),
                        " newSL=", DoubleToString(newSL, 2),
                        " currentSL=", DoubleToString(curSL, 2),
                        " (摆动点不在当前SL内侧, 不移动)");
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void CCommonTradingModule::OnTrade()
{
   IsNewTradingDay();
   if(TimeCurrent() - m_lastHistoryCheck < 1) return;
   m_lastHistoryCheck = TimeCurrent();

   datetime startTime = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   datetime endTime = TimeCurrent();
   HistorySelect(startTime, endTime);
   int total = HistoryDealsTotal();
   if(total <= 0) return;

   static ulong s_lastProcessedTicket = 0;
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || ticket <= s_lastProcessedTicket) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      OnDealProcessed(ticket, profit + swap + commission);
      s_lastProcessedTicket = ticket;
   }
}

//+------------------------------------------------------------------+
void CCommonTradingModule::OnTimer()
{
   IsNewTradingDay();
   if(m_pauseUntil > 0 && TimeCurrent() >= m_pauseUntil)
   {
      m_pauseUntil = 0;
      m_consecutiveLoss = 0;
      Print("🟢 连续亏损暂停到期, 恢复开仓");
   }
}

//+------------------------------------------------------------------+
//| 手数规范化                                                        |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   lots = MathFloor(lots / lotStep) * lotStep;
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| 按ticket选择持仓                                                  |
//+------------------------------------------------------------------+
bool MySelectPosition(ulong ticket)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == ticket) return true;
   }
   return false;
}

#endif // C_COMMON_TRADING_MODULE_MQH


//+------------------------------------------------------------------+
//| ★顺势突破策略: 策略主体代码                                      |
//+------------------------------------------------------------------+

//--- 全局对象
CCommonTradingModule g_Common;
CTrade               g_trade;

//--- 指标句柄
int    g_hFastMA   = INVALID_HANDLE;
int    g_hSlowMA   = INVALID_HANDLE;

//--- 状态
datetime g_lastEntryBarTime = 0;     // 上次入场K线时间(同bar1信号去重)
datetime g_lastKeyBarTime   = 0;     // ★v1.01 上次入场使用的关键位K线时间戳(同一关键位只交易一次)
datetime g_lastBarTime      = 0;     // 上次处理的M1 K线时间
int      g_trendDir         = 0;     // 趋势: 1=多 -1=空 0=未知
int      g_magic            = 20260819;
datetime g_endCloseDate     = 0;     // 已执行收盘强平的北京日期(00:00归一化, 跨日重置)

//+------------------------------------------------------------------+
//| 专家初始化                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   g_magic = 20260819;
   g_lastEntryBarTime = 0;
   g_lastKeyBarTime   = 0;   // ★v1.01 关键位去重状态初始化
   g_lastBarTime      = 0;
   g_trendDir         = 0;
   g_endCloseDate     = 0;

   //--- 参数校验
   if(InpFastMAPeriod < 2) { Print("❌ 快线MA周期必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpSlowMAPeriod < 2) { Print("❌ 慢线MA周期必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpSwingStrength < 2) { Print("❌ 摆动点强度必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpSwingLookback < 5) { Print("❌ 摆动点回看K线数必须>=5"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpRewardRiskRatio <= 0.1) { Print("❌ 盈亏比必须>0.1"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpUseEndCloseAll && InpCloseAllMinsBeforeEnd < 1) { Print("❌ 收盘强平提前量必须>=1分钟"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpNoEntryMinsBeforeEnd < 0) { Print("❌ 禁开仓提前量必须>=0"); return(INIT_PARAMETERS_INCORRECT); }

   //--- 通用模块初始化
   if(!g_Common.Init(g_magic, "SBTD"))
   {
      Print("❌ 通用模块初始化失败");
      return(INIT_FAILED);
   }

   //--- 交易对象配置
   g_trade.SetExpertMagicNumber(g_magic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetAsyncMode(false);

   //--- 创建指标句柄
   g_hFastMA = iMA(_Symbol, InpTrendTF, InpFastMAPeriod, 0, InpFastMAMethod, InpMAApplied);
   if(g_hFastMA == INVALID_HANDLE) { Print("❌ 创建快线MA失败"); return(INIT_FAILED); }

   g_hSlowMA = iMA(_Symbol, InpTrendTF, InpSlowMAPeriod, 0, InpSlowMAMethod, InpMAApplied);
   if(g_hSlowMA == INVALID_HANDLE) { Print("❌ 创建慢线MA失败"); return(INIT_FAILED); }

   //--- 预热检查
   int needBars = MathMax(InpSlowMAPeriod + 50, InpSwingLookback + 30);
   if(Bars(_Symbol, InpPatternTF) < needBars)
   {
      Print("❌ K线数据不足, 需要至少", needBars, "根");
      return(INIT_FAILED);
   }

   //--- 初始化趋势方向
   UpdateTrendDirection();

   //--- 追踪互斥校验
   int trailCnt = (InpUseTrailingA ? 1 : 0) + (InpUseTrailingB ? 1 : 0) + (InpUseTrailingC ? 1 : 0);
   if(trailCnt > 1)
      Print("⚠️ 追踪A/B/C多个同时启用! 按 A>B>C 优先级执行 (请只开启一个)");

   EventSetTimer(2);

   Print("✅ 顺势突破策略 v1.17 启动 (v1.17: 关键位定义参照追踪C=左右2根确认, 开仓更灵敏)");
   Print("🖥️ 环境: 服务器=", AccountInfoString(ACCOUNT_SERVER),
         " 账户=", IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)),
         " 货币=", AccountInfoString(ACCOUNT_CURRENCY));
   Print("   TimeCurrent(服务器)=", TimeToString(TimeCurrent()),
         " GMT=", TimeToString(TimeGMT()),
         " 服务器时区=GMT", (ServerTZOffsetHours() >= 0 ? "+" : ""), IntegerToString(ServerTZOffsetHours()),
         " 当前北京时间=", TimeToString(BeijingTimeNow()));
   Print("   交易窗口 BJT ", InpTradeStartHour, ":", StringFormat("%02d", InpTradeStartMinute),
         "~次日", InpTradeEndHour, ":", StringFormat("%02d", InpTradeEndMinute),
         " 当前点差=", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), "点",
         " 诊断日志=", (InpDiagnosticLog ? "开" : "关"));
   Print("   ★入场方式: 唯一=顺势突破关键位(无其他入场)");
   Print("   ★v1.00 不持仓过夜: 收盘强平=", (InpUseEndCloseAll ? "开" : "关"),
         " 提前", InpCloseAllMinsBeforeEnd, "分钟强平全部持仓",
         " | 禁开仓提前", InpNoEntryMinsBeforeEnd, "分钟");
   Print("   品种:", _Symbol, " 关键位周期:", EnumToString(InpPatternTF), " 趋势周期:", EnumToString(InpTrendTF));
   Print("   趋势MA: EMA", InpFastMAPeriod, "/MA", InpSlowMAPeriod,
         " 初始趋势: ", (g_trendDir == 1 ? "多头" : (g_trendDir == -1 ? "空头" : "未确定")));
   Print("   关键位/摆动点确认: 左右各2根确认(参照追踪C定义) | 回看", InpSwingLookback, "根 (入场关键位+该波段起点)");
   if(InpUseRiskRewardRatio)
      Print("   出场: 固定盈亏比开 → SL=关键位±", InpSLBufferPts, "点缓冲; TP=SL×", DoubleToString(InpRewardRiskRatio, 1));
   else
      Print("   出场: 固定盈亏比关 → 基础固定 SL=", InpFixedSLPoints, "点 / TP=", InpFixedTPPoints, "点");
   Print("   风控: 最大止损限制=", (InpUseMaxSLPoints ? "开启" : "关闭"),
         " 上限=", InpMaxSLPoints, "点 | 最大同仓=", InpMaxPositions);
   if(InpUseTrailingA)
      Print("   追踪A: 渐进式 (激活=", InpTrailingAActivatePts, " 保本=", InpTrailingABreakEvenPts, ")");
   else if(InpUseTrailingB)
      Print("   追踪B: 一次性保本 (触发=", InpTrailingBTriggerPts, " 保护=", InpTrailingBProtectPts, ")");
   else if(InpUseTrailingC)
      Print("   追踪C: 形态追踪 (触发=", InpTrailingCTriggerPts, " 保护=", InpTrailingCProtectPts,
            " 形态偏移=", InpTrailingCSLBufferPts, " 回看=", InpTrailingCLookbackBars,
            " 跳过触发=", InpTrailingCUsePatternOnly, ")");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 专家反初始化                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_hFastMA != INVALID_HANDLE) IndicatorRelease(g_hFastMA);
   if(g_hSlowMA != INVALID_HANDLE) IndicatorRelease(g_hSlowMA);
   Print("🔴 EA停止, 原因代码:", reason);
}

//+------------------------------------------------------------------+
//| 报价事件                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1.【最优先】追踪止损: 必须在任何风控检查之前执行
   g_Common.OnTick();

   // 1.5 ★收盘强平: 距交易结束≤N分钟 → 强平全部持仓(不持仓过夜, 不论盈亏)
   CloseAllPositionsAtEnd();

   // 2. 新K线检测(用iTime时间戳, 稳定) ★v1.01: 统一用InpPatternTF
   //    旧逻辑硬编码PERIOD_M1, 若用户改InpPatternTF为M5会导致信号评估与新bar检测错位
   datetime curBarTime = iTime(_Symbol, InpPatternTF, 1);
   if(curBarTime == 0) return;

   // 3. 仅在新K线开盘时评估入场(收盘确认突破 → 下根K线开盘市价入场)
   if(curBarTime != g_lastBarTime)
   {
      g_lastBarTime = curBarTime;
      CheckEntry();
   }
}

//+------------------------------------------------------------------+
//| 交易事件                                                          |
//+------------------------------------------------------------------+
void OnTrade()
{
   g_Common.OnTrade();
}

//+------------------------------------------------------------------+
//| 定时器                                                            |
//+------------------------------------------------------------------+
void OnTimer()
{
   CloseAllPositionsAtEnd();   // ★无tick时也要保障强平
   g_Common.OnTimer();
   g_Common.OnTick();          // 非交易时间也要移动SL(项目经验)
}

//+------------------------------------------------------------------+
//| ★顺势突破策略: 收盘强平(不持仓过夜)                              |
//+------------------------------------------------------------------+
void CloseAllPositionsAtEnd()
{
   if(!InpUseEndCloseAll) return;

   int minsToEnd = MinutesToSessionEnd();
   if(minsToEnd > InpCloseAllMinsBeforeEnd) return;

   // 同一交易日已执行过强平 → 跳过
   MqlDateTime dt;
   TimeToStruct(BeijingTimeNow(), dt);
   datetime bjDay = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(g_endCloseDate == bjDay) return;

   int  closedCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic) continue;

      if(g_trade.PositionClose(ticket))
         closedCount++;
   }
   // ★v1.01修复: 无论有无持仓都记录日期, 避免每个tick空转遍历
   //   旧逻辑: closedCount=0时不记录 → 每次tick重复遍历(无持仓时也浪费)
   g_endCloseDate = bjDay;
   if(closedCount > 0)
      Print("⏰ [EndCloseAll] 强平", closedCount, "张持仓 | 距结束", minsToEnd, "分钟 (不论盈亏)");
}

//+------------------------------------------------------------------+
//| 主入场检查 (新M1 K线开盘时调用)                                  |
//| ★顺势突破策略: 唯一入场方式=顺势突破关键位                        |
//|   - EMA55/MA233金叉=多头趋势只做多, 死叉=空头趋势只做空           |
//|   - bar1盘中突破关键位 + 收盘站另一侧 → bar2开盘市价入场          |
//|   - SL: 关键位±InpSLBufferPts点; TP: 2.6:1盈亏比                  |
//|   - 一个顺势突破信号只开一次(iTime时间戳去重)                      |
//+------------------------------------------------------------------+
void CheckEntry()
{
   // 1. 风控检查
   if(!g_Common.IsTradingAllowed())
   {
      if(InpDiagnosticLog)
      {
         Print("🩺 诊断: 风控拦截(顺势突破) | 北京时间=", TimeToString(BeijingTimeNow()));
      }
      return;
   }

   // 2. 持仓上限
   int curPos = CountPositions();
   if(curPos >= InpMaxPositions)
   {
      if(InpDiagnosticLog)
         Print("🩺 诊断: 持仓已达上限(", InpMaxPositions, ") 拦截 | 当前=", curPos);
      return;
   }

   // 3. 趋势方向更新
   UpdateTrendDirection();
   if(InpUseTrendFilter && g_trendDir == 0)
   {
      if(InpDiagnosticLog)
         Print("🩺 诊断: 趋势方向=0(EMA与MA相等或数据未就绪) 暂不开仓");
      return;
   }

   // ★ 方向: 多头趋势只做多, 空头趋势只做空
   bool allowLong  = (!InpUseTrendFilter) || (g_trendDir >= 0);
   bool allowShort = (!InpUseTrendFilter) || (g_trendDir <= 0);

   // 4. 顺势突破关键位入场检测
   double slTarget = 0;
   datetime keyBarTime = 0;          // ★v1.01 当前信号关键位K线时间戳
   ENUM_ORDER_TYPE signal = WRONG_VALUE;
   string signalName = "";

   // ===== 空头: 顺势下跌突破关键位(跌破前期摆动低点) =====
   if(allowShort)
   {
      int mode = DetectBearBreak(slTarget, keyBarTime);
      if(mode == 1)
      {
         signal = ORDER_TYPE_SELL;
         signalName = "顺势突破关键位(空)";
      }
   }

   // ===== 多头: 顺势上涨突破关键位(升破前期摆动高点) =====
   if(signal == WRONG_VALUE && allowLong)
   {
      int mode = DetectBullBreak(slTarget, keyBarTime);
      if(mode == 1)
      {
         signal = ORDER_TYPE_BUY;
         signalName = "顺势突破关键位(多)";
      }
   }

   // 5. 无信号
   if(signal == WRONG_VALUE)
   {
      if(InpDiagnosticLog)
      {
         double fast[1], slow[1];
         CopyBuffer(g_hFastMA, 0, 1, 1, fast);
         CopyBuffer(g_hSlowMA, 0, 1, 1, slow);
         Print("🩺 诊断: 顺势突破未触发 | 趋势=", (g_trendDir == 1 ? "多头" : (g_trendDir == -1 ? "空头" : "0")),
               " EMA", InpFastMAPeriod, "=", DoubleToString(fast[0], 2),
               " MA", InpSlowMAPeriod, "=", DoubleToString(slow[0], 2),
               " | bar1 O=", DoubleToString(iOpen(_Symbol, InpPatternTF, 1), 2),
               " H=", DoubleToString(iHigh(_Symbol, InpPatternTF, 1), 2),
               " L=", DoubleToString(iLow(_Symbol, InpPatternTF, 1), 2),
               " C=", DoubleToString(iClose(_Symbol, InpPatternTF, 1), 2),
               " | 北京时间=", TimeToString(BeijingTimeNow()));
      }
      return;
   }

   // 6. ★v1.01 双重信号去重(一个顺势突破信号只开一次仓):
   //    ① 同一根bar1只开一次 (g_lastEntryBarTime)
   //    ② 同一个关键位K线只交易一次 (g_lastKeyBarTime) — 核心修复!
   //       突破L1开仓后, 只要价格仍低于L1(未形成新摆动低点), 后续每根K线
   //       FindSwingLow仍会返回L1 → 若不去重会重复开仓, 违反"只交易一次"
   datetime sigBarTime = iTime(_Symbol, InpPatternTF, 1);
   if(sigBarTime == g_lastEntryBarTime)
   {
      if(InpDiagnosticLog)
         Print("🩺 诊断: 同根K线已开仓, 顺势突破信号去重拦截 | bar1=", TimeToString(sigBarTime));
      return;
   }
   if(keyBarTime != 0 && keyBarTime == g_lastKeyBarTime)
   {
      if(InpDiagnosticLog)
         Print("🩺 诊断: 同一关键位已交易过, 顺势突破信号去重拦截 | 关键位K线=", TimeToString(keyBarTime),
               " [", signalName, "]");
      return;
   }

   // 7. 执行开仓
   double entryPrice = (signal == ORDER_TYPE_BUY)
                       ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ★v1.15 出场模式开关:
   //   InpUseRiskRewardRatio=true  → 固定盈亏比: SL=关键位规则(波段起点±缓冲), TP=SL×盈亏比
   //   InpUseRiskRewardRatio=false → 基础止盈止损: 固定SL=InpFixedSLPoints(300点), 固定TP=InpFixedTPPoints(660点)
   double slPoints = 0;
   double tpPoints = 0;
   if(InpUseRiskRewardRatio)
   {
      // ★ 固定盈亏比模式: SL按关键位规则定, TP=SL×盈亏比
      slPoints = MathAbs(entryPrice - slTarget) / _Point;
      if(slPoints < 10) slPoints = 10;   // 最小SL保护
      tpPoints = InpRewardRiskRatio * slPoints;
   }
   else
   {
      // ★ 基础止盈止损模式: 固定SL 300点 / 固定TP 660点 (SL基准=开仓价, 不再用关键位规则SL)
      slPoints = InpFixedSLPoints;
      tpPoints = InpFixedTPPoints;
      slTarget = (signal == ORDER_TYPE_BUY)
                 ? entryPrice - slPoints * _Point
                 : entryPrice + slPoints * _Point;
   }

   // ★ 风控: 止损空间过大则拒绝开仓
   if(InpUseMaxSLPoints && slPoints >= InpMaxSLPoints)
   {
      Print("⛔ 风控拦截! [", signalName, "] ", (signal == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " 止损点数=", DoubleToString(slPoints, 1),
            " ≥ 上限 ", InpMaxSLPoints, "点, 止损过大不开仓");
      return;
   }

   // ★ 止盈目标: TP = 入场 ± 止盈点数
   double tpTarget = (signal == ORDER_TYPE_BUY)
                     ? entryPrice + tpPoints * _Point
                     : entryPrice - tpPoints * _Point;

   if(g_Common.OpenPosition(signal, entryPrice, slPoints, tpPoints))
   {
      g_lastEntryBarTime = sigBarTime;
      g_lastKeyBarTime   = keyBarTime;   // ★v1.01 记录本次使用的关键位(同一关键位不再交易)

      // ★精确修正关键位SL/TP(顺势突破: SL设在关键位绝对价格, TP按盈亏比/固定660)
      ulong ticket = FindLastPositionTicket();
      if(ticket != 0)
         SetExactSLTP(ticket, slTarget, tpTarget);

      Print("🚀 开仓! [", signalName, "] ", (signal == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " SL=", DoubleToString(slTarget, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
            " 关键位K线=", TimeToString(keyBarTime),
            " 止损点数=", DoubleToString(slPoints, 1),
            " 止盈点数=", DoubleToString(tpPoints, 1),
            (InpUseRiskRewardRatio
             ? " (盈亏比" + DoubleToString(InpRewardRiskRatio, 1) + ":1)"
             : " (基础固定SL/TP)"));
   }
}

//+------------------------------------------------------------------+
//| ★顺势突破策略: 空头顺势下跌突破关键位                            |
//| 逻辑:                                                              |
//|   1. 找最近的摆动低点 L1 (★v1.17左右各2根确认=参照追踪C定义)     |
//|   2. 关键位 = L1 (向下突破的关键支撑位, 仅用于触发信号)            |
//|   3. 有效突破: bar1.Low < L1 AND bar1.Close < L1                  |
//|      (盘中跌破 + 收盘站下 = 真突破; 收盘站上 = 假突破剔除)         |
//|   4. ★v1.14止损 = 该波段起点摆动高点 H 上方 InpSLBufferPts 点      |
//|              该波段 = 从波段内最高摆动高点H起到L1为止的下跌波段    |
//| 返回: 1=标准 0=无信号                                              |
//| 输出: slTarget 止损绝对价, keyBarTime 关键位K线时间戳(去重)        |
//+------------------------------------------------------------------+
int DetectBearBreak(double &slTarget, datetime &keyBarTime)
{
   double point = _Point;
   double low1   = iLow(_Symbol, InpPatternTF, 1);
   double close1 = iClose(_Symbol, InpPatternTF, 1);

   // ★v1.17关键位定义参照追踪C: 左右各2根确认(strength=2, 金刚经范式), 不再用InpSwingStrength=3
   //   金刚经追踪C: int strength=2; for(i=strength+1...) → 起点=3
   int keyStrength = 2;                        // ★v1.17 参照追踪C摆动点定义
   int minGap = keyStrength + 1;               // = 3 (起点, 保证右翼确认)
   int idxL1 = FindSwingLow(minGap, InpSwingLookback, keyStrength);
   if(idxL1 <= 0) return 0;

   double L1 = iLow(_Symbol, InpPatternTF, idxL1);

   // ★有效突破: 盘中最低价跌破关键位 + 收盘收在关键位下方
   if(low1 < L1 && close1 < L1)
   {
      // ★v1.14: SL = 该下跌波段起点(波段内【最高】摆动高点 H) + 20点
      //   开仓逻辑不变(顺势突破关键位), 仅SL端点用区间最值:
      //   用户图上 1处=4494.10(波段真正起点/最高摆动高点), 2处=4491.60(关键位L1)
      //   正确SL = 1处上方20点 = 4494.30 (而非2处上方20点)
      //   FindExtremeHighInRange 取区间内【价格最高】的摆动点 = 波段起点
      //   ★v1.17 SL端点同样用 keyStrength=2 (与关键位定义一致)
      int idxH = FindExtremeHighInRange(idxL1 + 1,
                                        idxL1 + InpSwingLookback,
                                        keyStrength);
      if(idxH <= 0) return 0;
      double H = iHigh(_Symbol, InpPatternTF, idxH);
      // 安全: H必须 > L1 (否则不构成下跌波段)
      if(H <= L1) return 0;
      slTarget = H + InpSLBufferPts * point;
      keyBarTime = iTime(_Symbol, InpPatternTF, idxL1);
      if(InpDiagnosticLog)
      {
         Print("🟢 [顺势突破·空] L1=", DoubleToString(L1, 2),
               " (idx=", idxL1, ")  波段最高H=", DoubleToString(H, 2),
               " (idx=", idxH, ")  SL=", DoubleToString(slTarget, 2),
               " (+", InpSLBufferPts, "点 波段起点, 关键位strength=2)");
      }
      return 1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| ★顺势突破策略: 多头顺势上涨突破关键位(空头镜像)                  |
//| 逻辑:                                                              |
//|   1. 找最近的摆动高点 H1 (★v1.17左右各2根确认=参照追踪C定义)     |
//|   2. 关键位 = H1 (向上突破的关键阻力位, 仅用于触发信号)            |
//|   3. 有效突破: bar1.High > H1 AND bar1.Close > H1                  |
//|   4. ★v1.14止损 = 该波段起点摆动低点 L 下方 InpSLBufferPts 点      |
//|              该波段 = 从波段内最低摆动低点L起到H1为止的上涨波段    |
//+------------------------------------------------------------------+
int DetectBullBreak(double &slTarget, datetime &keyBarTime)
{
   double point = _Point;
   double high1 = iHigh(_Symbol, InpPatternTF, 1);
   double close1 = iClose(_Symbol, InpPatternTF, 1);

   // ★v1.17关键位定义参照追踪C: 左右各2根确认(strength=2, 金刚经范式), 不再用InpSwingStrength=3
   int keyStrength = 2;                        // ★v1.17 参照追踪C摆动点定义
   int minGap = keyStrength + 1;               // = 3 (起点, 保证右翼确认)
   int idxH1 = FindSwingHigh(minGap, InpSwingLookback, keyStrength);
   if(idxH1 <= 0) return 0;

   double H1 = iHigh(_Symbol, InpPatternTF, idxH1);

   if(high1 > H1 && close1 > H1)
   {
      // ★v1.14: SL = 该上涨波段起点(波段内【最低】摆动低点 L) - 20点 (空头镜像)
      //   开仓逻辑不变(顺势突破关键位), 仅SL端点用区间最值:
      //   多头镜像: 波段起点 = H1之前波段内【价格最低】的摆动低点
      //   FindExtremeLowInRange 取区间内【价格最低】的摆动点 = 波段起点
      //   ★v1.17 SL端点同样用 keyStrength=2 (与关键位定义一致)
      int idxL = FindExtremeLowInRange(idxH1 + 1,
                                       idxH1 + InpSwingLookback,
                                       keyStrength);
      if(idxL <= 0) return 0;
      double L = iLow(_Symbol, InpPatternTF, idxL);
      // 安全: L必须 < H1 (否则不构成上涨波段)
      if(L >= H1) return 0;
      slTarget = L - InpSLBufferPts * point;
      keyBarTime = iTime(_Symbol, InpPatternTF, idxH1);
      if(InpDiagnosticLog)
      {
         Print("🟢 [顺势突破·多] H1=", DoubleToString(H1, 2),
               " (idx=", idxH1, ")  波段最低L=", DoubleToString(L, 2),
               " (idx=", idxL, ")  SL=", DoubleToString(slTarget, 2),
               " (-", InpSLBufferPts, "点 波段起点, 关键位strength=2)");
      }
      return 1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| 摆动低点查找: 从fromIdx向maxIdx(更早方向)找摆动低点               |
//+------------------------------------------------------------------+
int FindSwingLow(int fromIdx, int maxIdx, int strength)
{
   int upperBound = MathMin(maxIdx, Bars(_Symbol, InpPatternTF) - strength - 1);
   for(int i = fromIdx; i <= upperBound; i++)
   {
      double low = iLow(_Symbol, InpPatternTF, i);
      bool isSwing = true;
      for(int j = 1; j <= strength; j++)
      {
         if(iLow(_Symbol, InpPatternTF, i - j) <= low) { isSwing = false; break; }
         if(iLow(_Symbol, InpPatternTF, i + j) <= low) { isSwing = false; break; }
      }
      if(isSwing) return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| 摆动高点查找 (从fromIdx向maxIdx更早方向)                          |
//+------------------------------------------------------------------+
int FindSwingHigh(int fromIdx, int maxIdx, int strength)
{
   int upperBound = MathMin(maxIdx, Bars(_Symbol, InpPatternTF) - strength - 1);
   for(int i = fromIdx; i <= upperBound; i++)
   {
      double high = iHigh(_Symbol, InpPatternTF, i);
      bool isSwing = true;
      for(int j = 1; j <= strength; j++)
      {
         if(iHigh(_Symbol, InpPatternTF, i - j) >= high) { isSwing = false; break; }
         if(iHigh(_Symbol, InpPatternTF, i + j) >= high) { isSwing = false; break; }
      }
      if(isSwing) return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| ★v1.14 区间内【最高】摆动高点 (SL波段端点用)                    |
//|   与 FindSwingHigh 的区别:                                         |
//|     FindSwingHigh:        返回区间内【最近】的摆动高点            |
//|     FindExtremeHighInRange: 返回区间内【价格最高】的摆动高点      |
//|   用途: SL的"该波段起点"必须取波段内真正极值点, 而非最近的局部反弹  |
//|   范围: [fromIdx, maxIdx], fromIdx=关键位紧后1根, maxIdx=关键位前40根|
//+------------------------------------------------------------------+
int FindExtremeHighInRange(int fromIdx, int maxIdx, int strength)
{
   int upperBound = MathMin(maxIdx, Bars(_Symbol, InpPatternTF) - strength - 1);
   if(upperBound < fromIdx) return -1;

   int    bestIdx  = -1;
   double bestHigh = -1.0;     // XAU 永远为正, -1 安全初始化

   for(int i = fromIdx; i <= upperBound; i++)
   {
      double high = iHigh(_Symbol, InpPatternTF, i);
      bool isSwing = true;
      for(int j = 1; j <= strength; j++)
      {
         if(iHigh(_Symbol, InpPatternTF, i - j) >= high) { isSwing = false; break; }
         if(iHigh(_Symbol, InpPatternTF, i + j) >= high) { isSwing = false; break; }
      }
      if(!isSwing) continue;

      if(high > bestHigh)
      {
         bestHigh = high;
         bestIdx  = i;
      }
   }
   return bestIdx;
}

//+------------------------------------------------------------------+
//| ★v1.14 区间内【最低】摆动低点 (SL波段端点用, 多头镜像)          |
//+------------------------------------------------------------------+
int FindExtremeLowInRange(int fromIdx, int maxIdx, int strength)
{
   int upperBound = MathMin(maxIdx, Bars(_Symbol, InpPatternTF) - strength - 1);
   if(upperBound < fromIdx) return -1;

   int    bestIdx = -1;
   double bestLow = DBL_MAX;

   for(int i = fromIdx; i <= upperBound; i++)
   {
      double low = iLow(_Symbol, InpPatternTF, i);
      bool isSwing = true;
      for(int j = 1; j <= strength; j++)
      {
         if(iLow(_Symbol, InpPatternTF, i - j) <= low) { isSwing = false; break; }
         if(iLow(_Symbol, InpPatternTF, i + j) <= low) { isSwing = false; break; }
      }
      if(!isSwing) continue;

      if(low < bestLow)
      {
         bestLow = low;
         bestIdx = i;
      }
   }
   return bestIdx;
}

//+------------------------------------------------------------------+
//| 趋势方向更新 (克罗: EMA55/MA233顺势)                              |
//+------------------------------------------------------------------+
void UpdateTrendDirection()
{
   double fast[3], slow[3];
   if(CopyBuffer(g_hFastMA, 0, 1, 3, fast) < 3) return;
   if(CopyBuffer(g_hSlowMA, 0, 1, 3, slow) < 3) return;

   // 金叉日志
   if(fast[0] > slow[0] && fast[1] <= slow[1])
   {
      if(g_trendDir != 1)
         Print("🔵 金叉! 快线=", DoubleToString(fast[0], 2), " > 慢线=", DoubleToString(slow[0], 2), " → 多头趋势");
   }
   else if(fast[0] < slow[0] && fast[1] >= slow[1])
   {
      if(g_trendDir != -1)
         Print("🔴 死叉! 快线=", DoubleToString(fast[0], 2), " < 慢线=", DoubleToString(slow[0], 2), " → 空头趋势");
   }

   // 无条件按当前均线位置更新方向
   if(fast[0] > slow[0])
      g_trendDir = 1;
   else if(fast[0] < slow[0])
      g_trendDir = -1;
   else
      g_trendDir = 0;
}

//+------------------------------------------------------------------+
//| 持仓数量统计(本EA)                                                |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| 查找本EA最近开仓的持仓ticket                                      |
//+------------------------------------------------------------------+
ulong FindLastPositionTicket()
{
   datetime latest = 0;
   ulong result = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime >= latest)
      {
         latest = openTime;
         result = ticket;
      }
   }
   return result;
}

//+------------------------------------------------------------------+
//| 精确设置关键位SL/TP (顺势突破: SL设在关键位绝对价格)             |
//| TP = 入场价 ± InpRewardRiskRatio × SL距离 (默认2.6:1)             |
//+------------------------------------------------------------------+
void SetExactSLTP(ulong ticket, double slTarget, double tpTarget)
{
   if(ticket == 0) return;
   if(!MySelectPosition(ticket)) return;

   double point = _Point;
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   // TP未提供则按盈亏比计算
   if(tpTarget <= 0)
   {
      double slDist = MathAbs(openPrice - slTarget);
      tpTarget = (posType == POSITION_TYPE_BUY)
                 ? openPrice + InpRewardRiskRatio * slDist
                 : openPrice - InpRewardRiskRatio * slDist;
   }

   double newSL = currentSL;
   double newTP = currentTP;

   // 关键位SL修正
   if(posType == POSITION_TYPE_BUY)
   {
      if(currentSL == 0 || currentSL < slTarget - point)
         newSL = slTarget;
   }
   else
   {
      if(currentSL == 0 || currentSL > slTarget + point)
         newSL = slTarget;
   }

   if(tpTarget > 0)
      newTP = tpTarget;

   // 校验
   if(newSL <= 0 || newTP <= 0) return;
   if(posType == POSITION_TYPE_BUY && newTP <= newSL) return;
   if(posType == POSITION_TYPE_SELL && newTP >= newSL) return;

   if(newSL != currentSL || newTP != currentTP)
   {
      if(!g_trade.PositionModify(ticket, newSL, newTP))
         PrintFormat("❌ 关键位SL/TP修正失败 ticket=%I64u retcode=%u (%s)",
                     ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| 交易事务事件 (顺势突破无需平仓冷却, 留空接口)                      |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // ★顺势突破策略采用 iTime 时间戳去重, 不需要 OnTradeTransaction 冷却
   //   若将来要加平仓冷却, 可在此实现(参考戴维策略v1.21)
}
//+------------------------------------------------------------------+