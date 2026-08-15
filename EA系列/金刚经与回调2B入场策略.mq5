//+------------------------------------------------------------------+
//|                    金刚经与回调入场策略.mq5                        |
//|                                                                   |
//|  基于《金刚经_黄金M1_形态突破 v1.10》独立拆分的回调入场策略        |
//|                                                                   |
//|  策略来源: 知识库三合一 + 用户回调企稳入场理念                     |
//|  ①《金刚经策略》: 平台突破/W底/M顶 3种形态                        |
//|     止损设在形态极值(颈线/平台高低点)                              |
//|  ②《克罗谈投资策略》: EMA55/MA233金叉死叉顺势(追市)               |
//|     只顺趋势方向做单, 每笔风险1%~3%                               |
//|  ③《技术分析常见形态》: W底=第二底高于第一底, M顶=第二顶低于第一顶 |
//|     收盘突破颈线确认(收盘价越过突破线原则)                        |
//|  ④ ★用户回调企稳理念: 顺大趋势 → 逆小回调 → 回调企稳后入场        |
//|     止损更小, 胜率更高 (防追高追空)                               |
//|                                                                   |
//|  周期: 黄金 M1 (主周期)                                           |
//|  趋势: EMA55/MA233金叉=多头(只做多) 死叉=空头(只做空)             |
//|  形态: 平台突破(只做顺趋势方向) / W底三模式 / M顶三模式           |
//|  回调: ★v2.02 2B法则入场(摆动确认2根; v2.01跌破+收回总窗口≤34根) |
//|       多头: 回调创低点L1 → 34根内跌破L1创L2 → 收盘收回L1上方开多  |
//|             或 L2未破L1且价差≤200点 + 企稳阳线开多 (空头镜像)     |
//|  入场: 形态/回调收盘确认 → 下根K线开盘市价入场                    |
//|  止损: 形态/波段极值 - 20点 (绝对价格, 每笔必带)                  |
//|  止盈: 强制 2:1 盈亏比 (TP = 入场价 ± 2×SL区间, 每笔必带)         |
//+------------------------------------------------------------------+
#property copyright "Senior Developer"
#property version   "2.03"
#property description "金刚经与回调入场策略: EMA55/MA233顺势 + 形态突破 + 2B法则回调入场(独立EA)"
#property description "① 趋势: EMA55/MA233金叉死叉只做顺势; W底/M顶三模式+平台突破"
#property description "② ★v2.00回调入场改2B法则: 破位收回(标准2B) / 双底未破+企稳阳线, 只顺大趋势"
#property description "③ v2.02: 摆动确认=2根; v2.01跌破+收回总窗口≤L1后34根; SL/TP 2:1"
#property description "④ 风控: 止损≥1500点拒开; 追踪A/B/C三选一; 分批止盈; 平仓冷却"
#property description "⑤ 防历史回放; 顺势关键位突破; 自动时区; 诊断日志"

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

//=== ★ 诊断日志(排查多终端开仓不一致) ===
input bool   InpDiagnosticLog      = false;  // ★v1.10: 详细诊断日志(开仓拦截原因+环境信息, 排查不一致时开启)

//=== ★ 仓位管理 ===
input bool   InpUseFixedLot        = true;   // true=固定手数 false=百分比
input double InpFixedLot           = 0.01;   // 固定手数
input double InpRiskPercent        = 1.0;    // 风险百分比(%)
input double InpMinLot             = 0.01;   // 最小手数
input double InpMaxLot             = 10.0;   // 最大手数

//=== ★ 止损止盈开关 (v1.04: 强制每笔带SL+TP, 必须为true) ===
input bool   InpUseFixedStopLoss   = true;   // 启用固定止损(强制true: 形态SL必带)
input bool   InpUseFixedTakeProfit = true;   // 启用固定止盈(强制true: 2:1 TP必带)

//=== ★ 止损与追踪(共用基础参数) ===
input int    InpFixedSLPoints      = 300;    // 固定止损点数
input int    InpFixedTPPoints      = 660;    // 固定止盈点数

//=== ★ 追踪方式A: 渐进式(持续追踪SL,二选一) ===
input bool   InpUseTrailingA       = false;  // 启用追踪A(与B互斥)  ← 勾选即用A
input int    InpTrailingAActivatePts = 20;   // A: 追踪激活利润点数
input int    InpTrailingABreakEvenPts = 320; // A: 保本点数(SL移入场价)

//=== ★ 追踪方式B: 一次性保本(触发后锁死,二选一) ===
input bool   InpUseTrailingB       = true;   // 启用追踪B(与A/C互斥)  ← 勾选即用B
input int    InpTrailingBTriggerPts  = 320;  // B: 触发保本的利润点数
input int    InpTrailingBProtectPts  = 20;   // B: 保护利润(SL移开仓±此点数)

//=== ★ 追踪方式C: 形态追踪止损(三选一, 与A/B互斥) ===
input bool   InpUseTrailingC       = false;  // 启用追踪C(与A/B互斥)  ← 勾选即用C
input int    InpTrailingCTriggerPts  = 300;  // C: 触发激活的利润点数(SL移到保本+保护点)
input int    InpTrailingCProtectPts  = 55;   // C: 激活后SL移到开仓±此保护利润点数
input int    InpTrailingCSLBufferPts = 20;   // C: 形态追踪SL距支撑/压力位缓冲(点)

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
//| 通用交易模块 (input 已按黄金法则在主文件声明)                      |
//| ★ v1.06修复: 改回尖括号<>从终端Include目录加载                     |
//|   部署: 把 .mqh 复制到 MT5 终端的 MQL5/Include/ 目录即可          |
//+------------------------------------------------------------------+
//| ⚠️ v1.07 自包含: 通用模块代码已嵌入本EA, 单文件即可编译           |
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
//| 服务器时区偏移(小时, 相对GMT)  ★v1.10新增                         |
//| 例: 服务器=GMT+2 → 返回2; 服务器=GMT+3 → 返回3                   |
//| 原理: TimeCurrent()(服务器时间) - TimeGMT()(GMT时间) 的时差        |
//| 注意: TimeGMT() 依赖电脑本地时区设置正确(香港/中国=GMT+8)         |
//+------------------------------------------------------------------+
int ServerTZOffsetHours()
{
   datetime server = TimeCurrent();
   datetime gmt    = TimeGMT();
   return (int)MathRound((server - gmt) / 3600.0);
}

//+------------------------------------------------------------------+
//| 当前北京时间 ★v1.10新增                                          |
//| InpAutoDetectServerTZ=true  → 自动检测服务器时区换算(推荐)        |
//| InpAutoDetectServerTZ=false → 用手动 InpServerHourDiff            |
//+------------------------------------------------------------------+
datetime BeijingTimeNow()
{
   datetime server = TimeCurrent();
   if(InpAutoDetectServerTZ)
   {
      int serverTZ = ServerTZOffsetHours();
      return server + (8 - serverTZ) * 3600;   // 北京=GMT+8
   }
   return server + InpServerHourDiff * 3600;
}

//+------------------------------------------------------------------+
//| 通用交易模块类                                                      |
//+------------------------------------------------------------------+
class CCommonTradingModule
{
private:
   CTrade      m_trade;              // 交易对象
   CPositionInfo m_positionInfo;     // 持仓信息
   COrderInfo  m_orderInfo;          // 订单信息

   datetime    m_lastTradeDay;       // 最后交易日（用于日亏损重置）
   double      m_dailyLoss;          // 当日累计亏损（正值）
   int         m_consecutiveLoss;    // 连续亏损次数
   datetime    m_pauseUntil;         // 暂停到期时间
   datetime    m_lastHistoryCheck;   // 上次历史订单检查时间

   //--- 【BUG #5 修复】持久化追踪索引
   // 容量 100（v4.03 之前的旧代码只有 10，第 11 单起永远静默失败）
   // 每次查找前先清理已平仓订单的槽位
   // 触发条件满足但 SL 不需要修改时打印诊断日志
   ulong       m_trailTickets[TRAIL_SLOT_COUNT];
   bool        m_trailSlotUsed[TRAIL_SLOT_COUNT];
   int         m_trailNextIdx;       // 下一个可写入的槽位

   //--- 内部辅助函数
   bool        IsNewTradingDay();
   void        UpdateConsecutiveLossFromHistory();
   bool        PositionSelectByTicket(ulong ticket);
   bool        IsTrailingAEnabled();
   bool        IsTrailingBEnabled();
   bool        IsTrailingCEnabled();
   bool        SafeModifyPosition(ulong ticket, double sl, double tp, string context);
   int         FindOrCreateTrailSlot(ulong ticket, bool& outCreated);
   void        PruneClosedTrailSlots();

public:
   //--- 初始化与事件
   bool        Init(ulong magicNumber, string tradeComment);
   void        OnTick();
   void        OnTrade();
   void        OnTimer();

   //--- 交易前置检查
   bool        IsTradeTimeAllowed();
   bool        IsTradingAllowed();
   bool        CheckSpreadLimit();
   bool        CheckDailyLossLimit();
   bool        CheckConsecutiveLossPause();

   //--- 仓位与开仓
   double      CalculateLotSize(double slPoints, ENUM_ORDER_TYPE orderType);
   bool        OpenPosition(ENUM_ORDER_TYPE orderType, double price, double slPoints, double tpPoints, string comment);
   bool        OpenPosition(ENUM_ORDER_TYPE orderType, double price, double slPoints, double tpPoints);

   //--- 持仓管理
   void        ApplyStopLossTakeProfit(ulong ticket);
   void        ApplyTrailingStop(ulong ticket);  // 追踪 A：渐进式
   void        ApplyTrailingB(ulong ticket);     // 追踪 B：一次性保本
   void        ApplyTrailingC(ulong ticket);     // 追踪 C：形态追踪止损
   void        ManageAllPositions();

   //--- 状态信息
   double      GetDailyLoss()        const { return m_dailyLoss; }
   int         GetConsecutiveLoss()  const { return m_consecutiveLoss; }
   datetime    GetPauseUntil()       const { return m_pauseUntil; }
};

//+------------------------------------------------------------------+
//| 初始化                                                              |
//+------------------------------------------------------------------+
bool CCommonTradingModule::Init(ulong magicNumber, string tradeComment)
{
   m_trade.SetExpertMagicNumber(magicNumber);
   m_trade.SetDeviationInPoints((ulong)InpMaxSpreadPoints);

   m_trade.LogLevel(LOG_LEVEL_ERRORS);
   m_trade.SetAsyncMode(false);

   m_lastTradeDay = TimeCurrent();
   m_dailyLoss = 0;
   m_consecutiveLoss = 0;
   m_pauseUntil = 0;
   m_lastHistoryCheck = 0;

   // 初始化持久化追踪索引（【BUG #5 修复】容量 100，旧代码 10 不够）
   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      m_trailTickets[i] = 0;
      m_trailSlotUsed[i] = false;
   }
   m_trailNextIdx = 0;

   // 初始化时从历史订单统计当日亏损和连续亏损
   UpdateConsecutiveLossFromHistory();

   // A/B/C 互斥校验
   int trailCount = (InpUseTrailingA ? 1 : 0) + (InpUseTrailingB ? 1 : 0) + (InpUseTrailingC ? 1 : 0);
   if(trailCount > 1)
   {
      Print("CommonModule: 警告 — 追踪A/B/C 同时启用了 ", trailCount, " 个，按 A > B > C 优先级处理，请只开启一个");
   }

   return true;
}

//+------------------------------------------------------------------+
//| 追踪 A 启用判断（A 勾选即启用，B 勾选无效）                          |
//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTrailingAEnabled()
{
   return InpUseTrailingA && !InpUseTrailingB;
}

//+------------------------------------------------------------------+
//| 追踪 B 启用判断（仅当 A 未勾选时 B 勾选才生效）                      |
//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTrailingBEnabled()
{
   return InpUseTrailingB && !InpUseTrailingA && !InpUseTrailingC;
}

//+------------------------------------------------------------------+
//| 追踪 C 启用判断（仅当 A/B 均未勾选时 C 勾选才生效）                 |
//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTrailingCEnabled()
{
   return InpUseTrailingC && !InpUseTrailingA && !InpUseTrailingB;
}

//+------------------------------------------------------------------+
//| 检查是否为新交易日                                                   |
//+------------------------------------------------------------------+
bool CCommonTradingModule::IsNewTradingDay()
{
   MqlDateTime lastDt, currDt;
   TimeToStruct(m_lastTradeDay, lastDt);
   TimeToStruct(TimeCurrent(), currDt);

   if(lastDt.day != currDt.day || lastDt.mon != currDt.mon || lastDt.year != currDt.year)
   {
      m_lastTradeDay = TimeCurrent();
      m_dailyLoss = 0;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 根据订单票号选择持仓                                                 |
//+------------------------------------------------------------------+
bool CCommonTradingModule::PositionSelectByTicket(ulong ticket)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == ticket)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 从历史订单统计连续亏损（启动时或跨日）                               |
//+------------------------------------------------------------------+
void CCommonTradingModule::UpdateConsecutiveLossFromHistory()
{
   if(!InpUseConsecutiveLossPause)
      return;

   datetime startTime = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   datetime endTime = TimeCurrent();

   m_consecutiveLoss = 0;

   HistorySelect(startTime, endTime);
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY)
         continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double net = profit + swap + commission;

      if(net > 0)
         break;  // 遇到盈利则停止统计连续亏损
      else
         m_consecutiveLoss++;
   }

   m_lastHistoryCheck = TimeCurrent();
}

//+------------------------------------------------------------------+
//| 检查交易时间（北京时间）                                            |
//| ★v1.10: 支持自动检测服务器时区, 消除多终端/多服务器时区差异       |
//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTradeTimeAllowed()
{
   datetime serverTime = TimeCurrent();
   // 北京时间: 自动检测(推荐) 或 手动HourDiff
   datetime beijingTime = BeijingTimeNow();

   MqlDateTime dt;
   TimeToStruct(beijingTime, dt);

   int currentMinutes = dt.hour * 60 + dt.min;
   int startMinutes = InpTradeStartHour * 60 + InpTradeStartMinute;
   int endMinutes = InpTradeEndHour * 60 + InpTradeEndMinute;

   // 结束时间跨天（例如 7:30 ~ 次日 3:30）
   if(endMinutes < startMinutes)
   {
      // 允许两段：start ~ 24:00 和 00:00 ~ end
      if(currentMinutes >= startMinutes || currentMinutes <= endMinutes)
         return true;
   }
   else
   {
      if(currentMinutes >= startMinutes && currentMinutes <= endMinutes)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| 检查是否允许交易（综合）                                             |
//+------------------------------------------------------------------+
bool CCommonTradingModule::IsTradingAllowed()
{
   if(!IsTradeTimeAllowed())
      return false;

   if(!CheckSpreadLimit())
      return false;

   if(!CheckDailyLossLimit())
      return false;

   if(!CheckConsecutiveLossPause())
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| 检查点差限制                                                         |
//+------------------------------------------------------------------+
bool CCommonTradingModule::CheckSpreadLimit()
{
   if(!InpUseSpreadLimit)
      return true;

   long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts > InpMaxSpreadPoints)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| 检查当日最大亏损限制                                                 |
//+------------------------------------------------------------------+
bool CCommonTradingModule::CheckDailyLossLimit()
{
   if(!InpUseDailyLossLimit)
      return true;

   IsNewTradingDay(); // 跨日重置

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double maxLoss = balance * InpDailyLossPercent / 100.0;

   if(m_dailyLoss >= maxLoss)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| 检查连续亏损暂停                                                     |
//+------------------------------------------------------------------+
bool CCommonTradingModule::CheckConsecutiveLossPause()
{
   if(!InpUseConsecutiveLossPause)
      return true;

   if(TimeCurrent() < m_pauseUntil)
      return false;

   // 暂停已到期，重置
   if(m_pauseUntil > 0 && TimeCurrent() >= m_pauseUntil)
   {
      m_pauseUntil = 0;
      m_consecutiveLoss = 0;
   }

   if(m_consecutiveLoss >= InpConsecutiveLossCount)
   {
      m_pauseUntil = TimeCurrent() + InpPauseMinutes * 60;
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| 计算手数                                                            |
//+------------------------------------------------------------------+
double CCommonTradingModule::CalculateLotSize(double slPoints, ENUM_ORDER_TYPE orderType)
{
   if(InpUseFixedLot)
   {
      double lots = InpFixedLot;
      lots = NormalizeLot(lots);
      return lots;
   }

   // 按风险百分比计算
   if(slPoints <= 0)
   {
      Print("CommonModule: SL points invalid, using min lot");
      return NormalizeLot(InpMinLot);
   }

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLotSym = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickSize <= 0 || tickValue <= 0 || lotStep <= 0)
   {
      Print("CommonModule: Symbol info invalid");
      return NormalizeLot(InpMinLot);
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;

   // 每手在SL点数的亏损 = 止损点数 * 每点价值 / 最小跳动价
   double lossPerLot = slPoints * tickValue / tickSize;
   double lots = riskAmount / lossPerLot;

   // 对齐到合约步长
   lots = MathFloor(lots / lotStep) * lotStep;

   // 限制范围
   lots = MathMax(lots, MathMax(minLot, InpMinLot));
   lots = MathMin(lots, MathMin(maxLotSym, InpMaxLot));

   return NormalizeLot(lots);
}

//+------------------------------------------------------------------+
//| 规范化手数（对齐到 SYMBOL_VOLUME_STEP）                              |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lotStep <= 0)
      lotStep = 0.01;

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return lots;
}

//+------------------------------------------------------------------+
//| 开仓（带注释）                                                       |
//+------------------------------------------------------------------+
bool CCommonTradingModule::OpenPosition(ENUM_ORDER_TYPE orderType, double price, double slPoints, double tpPoints, string comment)
{
   if(!IsTradingAllowed())
      return false;

   double lots = CalculateLotSize(slPoints, orderType);
   if(lots <= 0)
   {
      Print("CommonModule: Lot size is zero");
      return false;
   }

   double sl = 0, tp = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0)
      point = _Point;

   if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP)
   {
      if(InpUseFixedStopLoss && slPoints > 0)
         sl = price - slPoints * point;
      if(InpUseFixedTakeProfit && tpPoints > 0)
         tp = price + tpPoints * point;
   }
   else if(orderType == ORDER_TYPE_SELL || orderType == ORDER_TYPE_SELL_LIMIT || orderType == ORDER_TYPE_SELL_STOP)
   {
      if(InpUseFixedStopLoss && slPoints > 0)
         sl = price + slPoints * point;
      if(InpUseFixedTakeProfit && tpPoints > 0)
         tp = price - tpPoints * point;
   }

   bool result = m_trade.PositionOpen(_Symbol, orderType, lots, price, sl, tp, comment);

   if(!result)
   {
      Print("CommonModule: OpenPosition failed. Retcode: ", m_trade.ResultRetcode());
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| 开仓（默认注释）                                                       |
//+------------------------------------------------------------------+
bool CCommonTradingModule::OpenPosition(ENUM_ORDER_TYPE orderType, double price, double slPoints, double tpPoints)
{
   return OpenPosition(orderType, price, slPoints, tpPoints, "");
}

//+------------------------------------------------------------------+
//| 应用固定止损止盈（每单独立，未设置则补设）                           |
//+------------------------------------------------------------------+
void CCommonTradingModule::ApplyStopLossTakeProfit(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0)
      point = _Point;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   // 若追踪 A/B 已修改过 SL（currentSL 不等于 0），则不再覆盖
   if(currentSL != 0)
      return;

   // 若用户关闭了固定止损/止盈开关，则不补设
   if(!InpUseFixedStopLoss && !InpUseFixedTakeProfit)
      return;

   double newSL = 0, newTP = 0;

   if(posType == POSITION_TYPE_BUY)
   {
      if(InpUseFixedStopLoss && InpFixedSLPoints > 0)
         newSL = openPrice - InpFixedSLPoints * point;
      if(InpUseFixedTakeProfit && InpFixedTPPoints > 0)
         newTP = openPrice + InpFixedTPPoints * point;
   }
   else // POSITION_TYPE_SELL
   {
      if(InpUseFixedStopLoss && InpFixedSLPoints > 0)
         newSL = openPrice + InpFixedSLPoints * point;
      if(InpUseFixedTakeProfit && InpFixedTPPoints > 0)
         newTP = openPrice - InpFixedTPPoints * point;
   }

   if(newSL != 0 || newTP != 0)
      SafeModifyPosition(ticket, newSL, newTP, "ApplyStopLossTakeProfit");
}

//+------------------------------------------------------------------+
//| 追踪止损 A：渐进式（持续追踪SL+保本）                                |
//| - 利润达到 InpTrailingAActivatePts 后开始追踪 SL                    |
//| - 利润达到 InpTrailingABreakEvenPts 后将 SL 移到入场价（保本）       |
//+------------------------------------------------------------------+
void CCommonTradingModule::ApplyTrailingStop(ulong ticket)
{
   if(!IsTrailingAEnabled())
      return;

   if(!PositionSelectByTicket(ticket))
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0)
      point = _Point;

   double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL  = PositionGetDouble(POSITION_SL);
   double currentTP  = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;
   // 【BUG #1 修复】使用原始 Bid/Ask 价格差计算点数差，而不是 POSITION_PROFIT
   // 原因：POSITION_PROFIT 是货币盈亏，不含 swap/commission；如果用它反算等效点数，
   //       持仓过夜累积的 swap 会让"价格等价点数"偏低，导致追踪永远触发不到。
   //       改用纯价格差：profitPoints = (currentPrice - openPrice) / point
   //       这就是用户截图里说的"用原始 Bid/Ask 价格差触发"。
   double profitPoints = (posType == POSITION_TYPE_BUY)
                         ? (currentPrice - openPrice) / point
                         : (openPrice - currentPrice) / point;

   //--- 阶段 1：达到保本点数时，将 SL 移至入场价（保本锁）
   if(profitPoints >= InpTrailingABreakEvenPts && InpTrailingABreakEvenPts > 0)
   {
      double beSL = (posType == POSITION_TYPE_BUY) ? openPrice + 2 * point : openPrice - 2 * point;
      beSL = NormalizeDouble(beSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

      // 【BUG #4 修复】统一为 (currentSL==0) 强制分支 + 价格比较
      // 原因：之前 BUY 漏了 (currentSL==0) 判断，理论上当持仓从未设过 SL 时，
      //       若 newSL 恰好在 [0, point] 区间内，BUY 不会触发移动；SELL 因为
      //       显式 || currentSL==0 分支会触发，导致两侧行为不对称。
      bool needMove = false;
      if(posType == POSITION_TYPE_BUY)
      {
         if(currentSL == 0 || currentSL < beSL - point)
            needMove = true;
      }
      else // SELL
      {
         if(currentSL == 0 || currentSL > beSL + point)
            needMove = true;
      }

      if(needMove)
      {
         // 【关键】第三个参数必须传 currentTP，传 0 会清掉 660 点止盈
         SafeModifyPosition(ticket, beSL, currentTP, "ApplyTrailingStop.Phase1.BreakEven");
         return; // 保本已生效，本 tick 不再做持续追踪
      }
   }

   //--- 阶段 2：达到追踪激活点数时，持续追踪 SL（每 1 个点距离）
   if(profitPoints >= InpTrailingAActivatePts && InpTrailingAActivatePts > 0)
   {
      double newSL = 0;
      if(posType == POSITION_TYPE_BUY)
         newSL = currentPrice - 1 * point; // 紧贴当前价 +1 点的回撤容忍
      else
         newSL = currentPrice + 1 * point;

      newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

      // 【BUG #4 修复】同样为 BUY 补上 (currentSL==0) 强制分支
      bool needMove = false;
      if(posType == POSITION_TYPE_BUY)
      {
         if(currentSL == 0 || newSL > currentSL + point)
            needMove = true;
      }
      else // SELL
      {
         if(currentSL == 0 || newSL < currentSL - point)
            needMove = true;
      }

      // 【BUG #5 修复】诊断日志：触发条件已满足但 SL 不需要修改时
      // 附带完整状态（profit / newSL / currentSL）方便排查
      if(!needMove)
      {
         PrintFormat("[TrailingA.Phase2] SKIP ticket=%I64u profit=%.1fpts newSL=%.5f currentSL=%.5f (触发条件已满足但 SL 无需前移)",
                     ticket, profitPoints, newSL, currentSL);
         return;
      }

      SafeModifyPosition(ticket, newSL, currentTP, "ApplyTrailingStop.Phase2.Active");
   }
}

//+------------------------------------------------------------------+
//| 追踪止损 B：一次性保本（触发后锁死）                                |
//| - 利润达到 InpTrailingBTriggerPts 时，将 SL 移到开仓价 ±保护点数     |
//| - 触发一次后即锁定，不再移动                                        |
//+------------------------------------------------------------------+
void CCommonTradingModule::ApplyTrailingB(ulong ticket)
{
   if(!IsTrailingBEnabled())
      return;

   if(!PositionSelectByTicket(ticket))
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0)
      point = _Point;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- 若 SL 已经被移动过（不处于初始 0 或固定 SL 位置），则视为已锁死，不再处理
   // 通过判断 SL 是否已经在入场价 + 保护利润范围内来识别是否已触发
   double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;
   // 【BUG #1 修复】使用原始 Bid/Ask 价格差，不用 POSITION_PROFIT 反算（避免 swap 干扰）
   double profitPoints = (posType == POSITION_TYPE_BUY)
                         ? (currentPrice - openPrice) / point
                         : (openPrice - currentPrice) / point;

   // 未达到触发点数：保持原样
   if(profitPoints < InpTrailingBTriggerPts || InpTrailingBTriggerPts <= 0)
      return;

   // 计算目标 SL：开仓价 ± 保护利润点数
   double targetSL = 0;
   if(posType == POSITION_TYPE_BUY)
      targetSL = openPrice + InpTrailingBProtectPts * point;
   else
      targetSL = openPrice - InpTrailingBProtectPts * point;

   targetSL = NormalizeDouble(targetSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   //--- 一次性触发：仅当当前 SL 比目标 SL 更差时才移动
   // BUY：currentSL 小于 targetSL 才移动（保护利润）
   // SELL：currentSL 大于 targetSL 才移动（保护利润）
   // 【BUG #4 修复】为 BUY 补上 (currentSL==0) 强制分支，与 SELL 保持对称
   bool needMove = false;
   if(posType == POSITION_TYPE_BUY)
   {
      if(currentSL == 0 || currentSL < targetSL - point)
         needMove = true;
   }
   else // SELL
   {
      if(currentSL == 0 || currentSL > targetSL + point)
         needMove = true;
   }

   // 【BUG #5 修复】诊断日志：触发条件已满足但 SL 已经在 targetSL 附近
   if(!needMove)
   {
      PrintFormat("[TrailingB.OneShot] SKIP ticket=%I64u profit=%.1fpts targetSL=%.5f currentSL=%.5f (已锁死在保护位或更优位置)",
                  ticket, profitPoints, targetSL, currentSL);
      return;
   }

   if(needMove)
   {
      // 【关键】第三个参数必须传 currentTP，传 0 会清掉 660 点止盈
      SafeModifyPosition(ticket, targetSL, currentTP, "ApplyTrailingB.OneShotBreakEven");
   }
   // 触发后即锁死：下一次 tick 即使价格再上涨也不再移动
}

//+------------------------------------------------------------------+
//| 追踪止损 C：形态追踪止损（三选一，与 A/B 互斥）                     |
//| - 利润达到 InpTrailingCTriggerPts(300) 时，SL 移到开仓±保护利润(55)|
//| - 之后按形态移动：多头找最近支撑位(摆动低点)下方20点               |
//|                 空头找最近压力位(摆动高点)上方20点                 |
//| - 保留当前 TP（2:1 止盈）不动                                       |
//+------------------------------------------------------------------+
void CCommonTradingModule::ApplyTrailingC(ulong ticket)
{
   if(!IsTrailingCEnabled())
      return;

   if(!PositionSelectByTicket(ticket))
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0)
      point = _Point;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // 用原始 Bid/Ask 价格差计算点数(不受 swap 影响)
   double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;
   double profitPoints = (posType == POSITION_TYPE_BUY)
                         ? (currentPrice - openPrice) / point
                         : (openPrice - currentPrice) / point;

   // --- 阶段1: 利润未达触发点, 不动作 ---
   if(profitPoints < InpTrailingCTriggerPts || InpTrailingCTriggerPts <= 0)
      return;

   // --- 阶段2: 保本锁利 SL = 开仓价 ± 保护利润点数 ---
   double targetSL = 0;
   if(posType == POSITION_TYPE_BUY)
      targetSL = openPrice + InpTrailingCProtectPts * point;
   else
      targetSL = openPrice - InpTrailingCProtectPts * point;

   // --- 阶段3: 形态追踪 - 找最近支撑/压力摆动位 ---
   int swingIdx = -1;
   int strength = 2;                    // 简化摆动强度(形态追踪用2根足够)
   int maxIdx   = MathMin(60, Bars(_Symbol, InpPatternTF) - strength - 2);
   for(int i = strength + 1; i <= maxIdx; i++)
   {
      bool isSwing = true;
      if(posType == POSITION_TYPE_BUY)  // 支撑位 = 摆动低点
      {
         double low = iLow(_Symbol, InpPatternTF, i);
         for(int j = 1; j <= strength; j++)
         {
            if(iLow(_Symbol, InpPatternTF, i - j) <= low) { isSwing = false; break; }
            if(iLow(_Symbol, InpPatternTF, i + j) <= low) { isSwing = false; break; }
         }
         if(isSwing)
         {
            swingIdx = i;
            break;
         }
      }
      else                              // 压力位 = 摆动高点
      {
         double high = iHigh(_Symbol, InpPatternTF, i);
         for(int j = 1; j <= strength; j++)
         {
            if(iHigh(_Symbol, InpPatternTF, i - j) >= high) { isSwing = false; break; }
            if(iHigh(_Symbol, InpPatternTF, i + j) >= high) { isSwing = false; break; }
         }
         if(isSwing)
         {
            swingIdx = i;
            break;
         }
      }
   }

   // 找到形态位 → SL 放到支撑/压力位外缓冲
   if(swingIdx > 0)
   {
      if(posType == POSITION_TYPE_BUY)
      {
         double swingLow = iLow(_Symbol, InpPatternTF, swingIdx);
         double patternSL = swingLow - InpTrailingCSLBufferPts * point;
         if(patternSL > targetSL)          // 只向更有利方向移动
            targetSL = patternSL;
      }
      else
      {
         double swingHigh = iHigh(_Symbol, InpPatternTF, swingIdx);
         double patternSL = swingHigh + InpTrailingCSLBufferPts * point;
         if(patternSL < targetSL)          // 只向更有利方向移动
            targetSL = patternSL;
      }
   }

   targetSL = NormalizeDouble(targetSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   // 仅当 SL 比当前更有利时才移动
   bool needMove = false;
   if(posType == POSITION_TYPE_BUY)
   {
      if(currentSL == 0 || targetSL > currentSL + point)
         needMove = true;
   }
   else // SELL
   {
      if(currentSL == 0 || targetSL < currentSL - point)
         needMove = true;
   }

   if(!needMove)
   {
      PrintFormat("[TrailingC.Pattern] SKIP ticket=%I64u profit=%.1fpts targetSL=%.5f currentSL=%.5f (SL已更优)",
                  ticket, profitPoints, targetSL, currentSL);
      return;
   }

   // 【关键】保留当前TP, 不能传0
   SafeModifyPosition(ticket, targetSL, currentTP, "ApplyTrailingC.PatternTrailing");
}

//+------------------------------------------------------------------+
//| 安全的 PositionModify 包装：失败时打印 retcode + 上下文，方便排查   |
//| - 任何返回 false 的内部调用都会触发日志                               |
//| - context 用于定位是哪段追踪/补设逻辑                                |
//+------------------------------------------------------------------+
bool CCommonTradingModule::SafeModifyPosition(ulong ticket, double sl, double tp, string context)
{
   if(ticket == 0)
   {
      PrintFormat("[%s] PositionModify failed: ticket=0", context);
      return false;
   }

   if(!m_trade.PositionModify(ticket, sl, tp))
   {
      PrintFormat("[%s] PositionModify FAILED ticket=%I64u sl=%.5f tp=%.5f retcode=%u (%s)",
                  context,
                  ticket, sl, tp,
                  m_trade.ResultRetcode(),
                  m_trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 持久化追踪索引工具 (【BUG #5 修复】)                                |
//| - 容量 100（远超常见 EA 的同时持仓数）                              |
//| - 每次查找前自动清理已平仓订单的槽位（避免"只增不减"）              |
//| - 找不到可用槽位时返回 -1，调用方应处理这种情况                     |
//+------------------------------------------------------------------+
int CCommonTradingModule::FindOrCreateTrailSlot(ulong ticket, bool& outCreated)
{
   outCreated = false;
   if(ticket == 0)
      return -1;

   //--- 步骤 1：先查找（顺便清理已平仓的槽位）
   PruneClosedTrailSlots();

   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      if(m_trailSlotUsed[i] && m_trailTickets[i] == ticket)
         return i; // 已存在
   }

   //--- 步骤 2：未找到，找一个空闲槽位（环形查找，从 m_trailNextIdx 开始）
   for(int step = 0; step < TRAIL_SLOT_COUNT; step++)
   {
      int idx = (m_trailNextIdx + step) % TRAIL_SLOT_COUNT;
      if(!m_trailSlotUsed[idx])
      {
         m_trailTickets[idx] = ticket;
         m_trailSlotUsed[idx] = true;
         m_trailNextIdx = (idx + 1) % TRAIL_SLOT_COUNT;
         outCreated = true;
         return idx;
      }
   }

   //--- 步骤 3：100 个槽位都满了（极端情况：同时持仓 100+ 单）
   PrintFormat("[TrailSlot] 索引已满（容量=%d），ticket=%I64u 跳过追踪", TRAIL_SLOT_COUNT, ticket);
   return -1;
}

//+------------------------------------------------------------------+
//| 清理已平仓订单的槽位（【BUG #5 修复】自动清理）                      |
//+------------------------------------------------------------------+
void CCommonTradingModule::PruneClosedTrailSlots()
{
   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      if(!m_trailSlotUsed[i])
         continue;

      ulong ticket = m_trailTickets[i];
      if(ticket == 0)
      {
         m_trailSlotUsed[i] = false;
         continue;
      }

      // 检查订单是否还活着
      bool alive = false;
      for(int p = PositionsTotal() - 1; p >= 0; p--)
      {
         if(PositionGetTicket(p) == ticket)
         {
            alive = true;
            break;
         }
      }
      if(!alive)
      {
         m_trailTickets[i] = 0;
         m_trailSlotUsed[i] = false;
      }
   }
}

//+------------------------------------------------------------------+
//| 管理所有持仓：止损止盈、追踪止损(A/B/C 三选一)                      |
//| 【BUG #2 修复】必须放在 OnTick 第一行，g_Common.OnTick() 之前！      |
//| 本函数不受 IsTradingAllowed 限制                                    |
//| 即使在非交易时间/日亏损/点差超标时，也会执行保本追踪                  |
//| 灾难场景：若先调 IsTradingAllowed() 再 return，已持仓的保本追踪     |
//|          永远不会被触发；下次行情回撤直接穿仓。                     |
//+------------------------------------------------------------------+
void CCommonTradingModule::ManageAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      // 先补设基础 SL/TP
      ApplyStopLossTakeProfit(ticket);

      // 再根据模式执行追踪（A 优先；未启用 A 再用 B；未启用 B 再用 C）
      if(IsTrailingAEnabled())
         ApplyTrailingStop(ticket);
      else if(IsTrailingBEnabled())
         ApplyTrailingB(ticket);
      else if(IsTrailingCEnabled())
         ApplyTrailingC(ticket);
   }
}

//+------------------------------------------------------------------+
//| OnTick 事件处理：管理持仓                                            |
//+------------------------------------------------------------------+
void CCommonTradingModule::OnTick()
{
   ManageAllPositions();
}

//+------------------------------------------------------------------+
//| OnTrade 事件处理：统计日亏损和连续亏损                                |
//+------------------------------------------------------------------+
void CCommonTradingModule::OnTrade()
{
   IsNewTradingDay(); // 跨日重置

   // 仅每隔一段时间检查历史，避免频繁调用
   if(TimeCurrent() - m_lastHistoryCheck < 1)
      return;

   m_lastHistoryCheck = TimeCurrent();

   datetime startTime = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   datetime endTime = TimeCurrent();

   HistorySelect(startTime, endTime);
   int total = HistoryDealsTotal();

   // 本次只处理最新的平仓交易
   // 注意：OnTrade 可能重复触发，需要通过记录上次处理票号避免重复
   static ulong s_lastProcessedTicket = 0;

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(ticket <= s_lastProcessedTicket)
         continue;

      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY)
         continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double net = profit + swap + commission;

      if(net < 0)
      {
         m_dailyLoss += MathAbs(net);
         m_consecutiveLoss++;

         // 检查是否触发连续亏损暂停
         if(InpUseConsecutiveLossPause && m_consecutiveLoss >= InpConsecutiveLossCount)
            m_pauseUntil = TimeCurrent() + InpPauseMinutes * 60;
      }
      else
      {
         m_consecutiveLoss = 0;
      }

      s_lastProcessedTicket = ticket;
   }
}

//+------------------------------------------------------------------+
//| OnTimer 事件处理：检查暂停到期、跨日重置                               |
//+------------------------------------------------------------------+
void CCommonTradingModule::OnTimer()
{
   IsNewTradingDay();

   if(m_pauseUntil > 0 && TimeCurrent() >= m_pauseUntil)
   {
      m_pauseUntil = 0;
      m_consecutiveLoss = 0;
   }
}

#endif // C_COMMON_TRADING_MODULE_MQH


//+------------------------------------------------------------------+
//| ★ 策略输入参数                                                    |
//+------------------------------------------------------------------+
input group "=== ★ 形态开关 ==="
input bool   InpUseWBottom       = true;     // 启用W底-标准(突破颈线)
input bool   InpUseWBAggr1       = true;     // 启用W底-激进①(第二底未破第一底+回调≥50%反弹+阳线收过第一底K线高)
input bool   InpUseWBAggr2       = true;     // 启用W底-激进②(第二底破位但5根内阳线收回)
input bool   InpUseMTop          = true;     // 启用M顶-标准(跌破颈线)
input bool   InpUseMTopAggr1     = true;     // 启用M顶-激进①(第二顶未破第一顶+反弹≥50%回调+阴线收破第一顶K线低)
input bool   InpUseMTopAggr2     = true;     // 启用M顶-激进②(第二顶破位但5根内阴线收回)
input bool   InpUsePlatform      = true;     // ★v1.22 启用顺势关键位突破(金叉多头突破前高做多,死叉空头跌破前低做空)

input group "=== ★ 激进①回调深度(防追单) ==="
input double InpAggrPullbackPct  = 0.50;     // 激进①回调深度: 第二底回调≥反弹幅度的此比例

input group "=== ★ v2.02 回调入场: 2B法则(回调板块摆动确认=2根, 与全局InpSwingStrength=3解耦) ==="
input bool   InpUsePullbackEntry   = true;   // 启用2B法则回调入场(总开关)
input int    Inp2BMaxBars          = 34;     // ★v2.01总窗口: L1出现后跌破+收回全程≤此根数(34根=34分钟)
input int    Inp2BMaxGapPts        = 200;    // 2B: 两低点/两高点最大价差(点, 200点=2美金)
input double InpPullbackPctMin      = 0.50;  // 回调幅度最低比例(前一波段的此比例, 防追高)
input int    InpPullbackLookback    = 60;    // 波段/摆动点搜索回看K线数
input double InpPullbackStabBodyPct = 0.30;  // 企稳K线实体占比下限(避免十字星假企稳)

input group "=== ★ EMA55/MA233 趋势判断(克罗: 顺势追市) ==="
input bool   InpUseTrendFilter   = true;     // 启用EMA55/MA233趋势判断(只顺趋势)
input int    InpFastMAPeriod     = 55;       // 快线EMA周期(EMA55)
input ENUM_MA_METHOD InpFastMAMethod = MODE_EMA;  // 快线MA类型
input int    InpSlowMAPeriod     = 233;      // 慢线MA周期(MA233)
input ENUM_MA_METHOD InpSlowMAMethod = MODE_SMA;  // 慢线MA类型
input ENUM_APPLIED_PRICE InpMAApplied = PRICE_CLOSE; // MA应用价格
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_M1; // 趋势过滤周期

input group "=== ★ 形态参数 ==="
input ENUM_TIMEFRAMES InpPatternTF = PERIOD_M1; // 形态识别周期
input int    InpSwingStrength    = 3;        // 摆动点强度(左右各N根确认)
input int    InpSwingLookback    = 40;       // 摆动点搜索回看K线数(W底/M顶)
input int    InpMinWavePts       = 30;       // 最小波幅(摆动点间最小距离,点)
input int    InpNeckHeightMinPts = 200;      // ★v1.13 颈线距两底/两顶最小高度(点, 标准模式要求≥此值)
input int    InpNeckBufferPts    = 8;        // 颈线突破确认缓冲(点)
input int    InpAggrRecoverBars  = 5;        // 激进②破位后收回K线数上限(默认5根)
input int    InpPlatLookback     = 15;       // 平台回看K线数
input int    InpPlatMaxRangePts  = 150;      // 平台最大区间(点)

input group "=== ★ v1.22 防追高(颈线突破约束, W底/M顶标准模式) ==="
input bool   InpRequireFirstBreak = true;    // ★v1.22 要求bar1是首次突破(bar2最高<颈线才开仓, 防震荡后偶然突破)
input int    InpMaxBreakoutDistPts = 100;    // ★v1.22 bar1收盘距离颈线最大点数(超出视为追高, 拒绝开仓)
input int    InpMaxNeckAgeBars    = 30;      // ★v1.22 颈线距今最大K线数(颈线太老不构成有效形态)

input group "=== ★ 出场参数 ==="
input int    InpSLBufferPts      = 20;       // 形态止损缓冲(点)
input int    InpMaxPositions     = 2;        // ★v1.15 最大同时持仓数(2=分批止盈平部分后可开新仓)
input double InpRewardRiskRatio  = 2.0;      // 盈亏比(TP/SL倍数): 2=2:1, 3=3:1, 5=5:1等

input group "=== ★ v1.15 分批止盈(独立开关, 每档比例可调) ==="
input bool   InpUseTieredTP      = true;     // 启用分批止盈(利润达1/2/3倍止损空间分批平仓)
input double InpTier1ProfitMult  = 1.0;      // 第1档触发: 利润达此倍止损空间
input double InpTier1ClosePct    = 0.33;     // 第1档平仓比例(占总仓位): 0.25=1/4, 0.33=1/3, 0.50=1/2
input double InpTier2ProfitMult  = 2.0;      // 第2档触发: 利润达此倍止损空间
input double InpTier2ClosePct    = 0.50;     // 第2档平仓比例(占剩余仓位)
input double InpTier3ProfitMult  = 3.0;      // 第3档触发: 利润达此倍止损空间
input double InpTier3ClosePct    = 1.00;     // 第3档平仓比例(剩余全部, 默认1.0)

input group "=== ★ v1.14 平仓冷却(同根K线禁止再开仓) ==="
input bool   InpUseCloseCooldown = true;     // 启用平仓冷却(在该根K线上刚平仓 → 禁止再开仓)
input int    InpCloseCooldownBars = 1;       // 平仓后禁止开仓的K线数(1=仅平仓所在K线, 2=平仓后1根也禁止)

input group "=== ★ 风控: 最大止损限制 ==="
input bool   InpUseMaxSLPoints   = true;     // 启用最大止损限制(止损过大不开仓)
input int    InpMaxSLPoints      = 1500;     // 最大允许止损点数(默认1500点=15美金)

//+------------------------------------------------------------------+
//| 全局对象                                                          |
//+------------------------------------------------------------------+
CCommonTradingModule g_Common;
CTrade               g_trade;

//--- 指标句柄
int    g_hFastMA   = INVALID_HANDLE;
int    g_hSlowMA   = INVALID_HANDLE;

//--- 状态
datetime g_lastEntryBarTime = 0;   // 上次入场K线时间(信号去重)
datetime g_lastBarTime      = 0;   // 上次处理的M1 K线时间
int      g_trendDir         = 0;   // 趋势: 1=多 -1=空 0=未知
int      g_magic            = 20260812;
datetime g_lastCloseBarTime = 0;   // 上次平仓所在K线时间(同根K线冷却用)

//+------------------------------------------------------------------+
//| ★v1.15 分批止盈状态槽位 (每持仓记录: 止损空间 + 已执行档位)        |
//+------------------------------------------------------------------+
struct TierState
{
   ulong  ticket;        // 持仓号 (0=空槽)
   double slPoints;      // 该单止损点数 (1/2/3倍利润基准)
   int    tierReached;   // 已执行档位: 0=未平 1=已平1档 2=已平2档 3=已平3档(全平)
};
TierState g_tierSlots[TRAIL_SLOT_COUNT];
bool      g_anyTier1Triggered = false;  // ★v1.16 是否有任意持仓走过第1档分批止盈(触发后才允许开第2仓)
string    g_gvTier1Fired = "";          // ★v1.17 持久化键名(用magic区分EA), EA重启状态保留

//+------------------------------------------------------------------+
//| ★v1.17 持久化辅助: 跨EA重启保留分批止盈第1档触发状态              |
//+------------------------------------------------------------------+
void LoadTier1FiredFlag()
{
   g_anyTier1Triggered = (GlobalVariableCheck(g_gvTier1Fired) && GlobalVariableGet(g_gvTier1Fired) > 0.5);
}
void SaveTier1FiredFlag()
{
   g_anyTier1Triggered = true;
   GlobalVariableSet(g_gvTier1Fired, 1.0);
}

//+------------------------------------------------------------------+
//| 专家初始化                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   g_magic = 20260812;
   g_gvTier1Fired = "JGJ_PB_T1F_" + IntegerToString(g_magic);  // ★v1.17 用magic区分持久化键
   g_lastCloseBarTime = 0;
   g_anyTier1Triggered = false;
   ZeroMemory(g_tierSlots);
   LoadTier1FiredFlag();  // ★v1.17 从MT5全局变量恢复触发状态(跨EA重启)

   //--- 参数校验
   if(InpFastMAPeriod < 2) { Print("❌ 快线MA周期必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpSlowMAPeriod < 2) { Print("❌ 慢线MA周期必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpSwingStrength < 2) { Print("❌ 摆动点强度必须>=2"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpPlatLookback < 5)  { Print("❌ 平台回看K线数必须>=5"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpRewardRiskRatio <= 0.1) { Print("❌ 盈亏比必须>0.1"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpUseTieredTP)
   {
      if(InpTier1ClosePct <= 0 || InpTier1ClosePct >= 1.0) { Print("❌ 第1档平仓比例须在(0,1)"); return(INIT_PARAMETERS_INCORRECT); }
      if(InpTier2ClosePct <= 0 || InpTier2ClosePct >= 1.0) { Print("❌ 第2档平仓比例须在(0,1)"); return(INIT_PARAMETERS_INCORRECT); }
      if(InpTier3ProfitMult <= InpTier2ProfitMult) { Print("❌ 第3档触发倍数必须>第2档"); return(INIT_PARAMETERS_INCORRECT); }
   }

   //--- 通用模块初始化
   if(!g_Common.Init(g_magic, "JGJ_PB"))
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
   int needBars = MathMax(InpSlowMAPeriod + 50, InpPlatLookback + InpSwingLookback + 30);
   if(Bars(_Symbol, InpPatternTF) < needBars)
   {
      Print("❌ K线数据不足, 需要至少", needBars, "根");
      return(INIT_FAILED);
   }

   //--- 初始化趋势方向
   UpdateTrendDirection();

   //--- 追踪互斥校验
   if(InpUseTrailingA && InpUseTrailingB)
      Print("⚠️ 追踪A和B同时开启! 按A优先执行 (请只开启一个)");

   EventSetTimer(2);

   Print("✅ 金刚经与回调2B入场策略 v2.03 启动");
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
   Print("   品种:", _Symbol, " 形态周期:", EnumToString(InpPatternTF), " 趋势周期:", EnumToString(InpTrendTF));
   Print("   形态: W底=", InpUseWBottom, "(激进①=", InpUseWBAggr1, " 激进②=", InpUseWBAggr2, ")",
         " M顶=", InpUseMTop, "(激进①=", InpUseMTopAggr1, " 激进②=", InpUseMTopAggr2, ")",
         " 平台=", InpUsePlatform);
   Print("   EMA55/MA233趋势判断: ", (InpUseTrendFilter ? "开启(只做顺势)" : "关闭(多空双向)"));
   Print("   趋势MA: ", InpFastMAPeriod, "/", InpSlowMAPeriod,
         " 初始趋势: ", (g_trendDir == 1 ? "多头" : "空头"));
   Print("   出场: 每笔强制SL(形态极值) + TP(", DoubleToString(InpRewardRiskRatio, 1), ":1盈亏比, 可调)");
   Print("   风控: 最大止损限制=", (InpUseMaxSLPoints ? "开启" : "关闭"),
         " 上限=", InpMaxSLPoints, "点 (", DoubleToString(InpMaxSLPoints * _Point, 2), "美元)");
   if(InpUseTrailingA)
      Print("   追踪A: 渐进式 (激活=", InpTrailingAActivatePts, " 保本=", InpTrailingABreakEvenPts, ")");
   else if(InpUseTrailingB)
      Print("   追踪B: 一次性保本 (触发=", InpTrailingBTriggerPts, " 保护=", InpTrailingBProtectPts, ")");
   else if(InpUseTrailingC)
      Print("   追踪C: 形态追踪 (触发=", InpTrailingCTriggerPts, " 保护=", InpTrailingCProtectPts,
            " 形态缓冲=", InpTrailingCSLBufferPts, ")");
   Print("   激进①回调深度: ≥ 反弹幅度的 ", InpAggrPullbackPct * 100, "% (防追单)");
   Print("   ★v1.14 平仓冷却: ", (InpUseCloseCooldown ? "启用" : "禁用"),
         " 平仓后", InpCloseCooldownBars, "根K线内禁止再开仓 | 盈亏比=", DoubleToString(InpRewardRiskRatio, 1), ":1");
   Print("   ★v1.15 分批止盈: ", (InpUseTieredTP ? "启用" : "禁用"),
         " 第1档@", DoubleToString(InpTier1ProfitMult, 1), "xSL平", DoubleToString(InpTier1ClosePct * 100, 0), "%",
         " 第2档@", DoubleToString(InpTier2ProfitMult, 1), "xSL平剩余", DoubleToString(InpTier2ClosePct * 100, 0), "%",
         " 第3档@", DoubleToString(InpTier3ProfitMult, 1), "xSL平剩余", DoubleToString(InpTier3ClosePct * 100, 0), "%",
         " | 最大持仓=", InpMaxPositions);
   Print("   ★v1.17 分批保护: InpUseTieredTP=", (InpUseTieredTP ? "true" : "false"),
         " → 第1档触发=", (g_anyTier1Triggered ? "已触发(允许开第2仓)" : "未触发(第2仓将拦截)"),
         " | GV=", g_gvTier1Fired,
         " | GV值=", (GlobalVariableCheck(g_gvTier1Fired) ? DoubleToString(GlobalVariableGet(g_gvTier1Fired), 0) : "不存在"));
   Print("   ★v2.02 2B法则回调入场: ", (InpUsePullbackEntry ? "启用" : "禁用"),
         " | 摆动确认=2根",
         " | 跌破+收回总窗口≤", Inp2BMaxBars, "根",
         " | 两低点价差≤", Inp2BMaxGapPts, "点",
         " | 回调≥", InpPullbackPctMin * 100, "%",
         " | 回看=", InpPullbackLookback, "根",
         " | 实体占比≥", InpPullbackStabBodyPct * 100, "%");

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

   // 2. ★v1.15 分批止盈: 利润达1/2/3倍止损空间时按比例分批平仓
   CheckTieredTP();

   // 3. 新M1 K线检测(用iTime时间戳, 稳定)
   datetime curBarTime = iTime(_Symbol, PERIOD_M1, 1);
   if(curBarTime == 0) return;

   // 4. 仅在新K线开盘时评估入场(收盘确认形态 → 下根K线开盘入场)
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
//| 定时器(保障无Tick时追踪可用)                                       |
//+------------------------------------------------------------------+
void OnTimer()
{
   g_Common.OnTimer();
   g_Common.OnTick();   // 非交易时间也要移动SL(项目v1.25经验)
   CheckTieredTP();     // ★v1.15 非交易时间也要执行分批止盈
}

//+------------------------------------------------------------------+
//| ★v1.15 分批止盈核心逻辑                                           |
//| 利润达1倍止损空间 → 平总仓位InpTier1ClosePct(默认1/3)             |
//| 利润达2倍止损空间 → 平剩余仓位InpTier2ClosePct(默认1/2)           |
//| 利润达3倍止损空间 → 平剩余全部(InpTier3ClosePct=1.0)             |
//| 每档触发倍数/平仓比例均可调 (控制面板)                            |
//+------------------------------------------------------------------+
void CheckTieredTP()
{
   if(!InpUseTieredTP) return;

   // 清理已平仓槽位 (持仓不存在 → 清空)
   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      if(g_tierSlots[i].ticket != 0)
      {
         bool exists = false;
         for(int j = PositionsTotal() - 1; j >= 0; j--)
         {
            ulong t = PositionGetTicket(j);
            if(t == g_tierSlots[i].ticket) { exists = true; break; }
         }
         if(!exists)
            g_tierSlots[i].ticket = 0;
      }
   }

   // 遍历本EA所有持仓
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(!MySelectPosition(ticket)) continue;

      // 找该持仓的分批止盈槽位
      int slot = FindTierSlot(ticket);
      if(slot < 0) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      double slPoints  = g_tierSlots[slot].slPoints;
      if(slPoints <= 0) continue;

      // 当前利润点数 (多头: 现价-入场; 空头: 入场-现价) 用Bid/Ask分别计算
      double curPrice = (ptype == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (ptype == POSITION_TYPE_BUY)
                         ? (curPrice - openPrice) / _Point
                         : (openPrice - curPrice) / _Point;

      // ---- 第1档: 利润 ≥ 1倍止损空间 → 平总仓位比例 ----
      if(g_tierSlots[slot].tierReached == 0 && profitPts >= InpTier1ProfitMult * slPoints)
      {
         double closeLots = NormalizeLot(volume * InpTier1ClosePct);
         if(closeLots > 0 && closeLots < volume)
         {
            if(g_trade.PositionClosePartial(ticket, closeLots))
            {
               g_tierSlots[slot].tierReached = 1;
               SaveTier1FiredFlag();   // ★v1.17 同步持久化触发状态(EA重启后仍生效)
               Print("🎯 分批止盈1档: [ticket=", ticket, "] 利润", DoubleToString(profitPts, 1),
                     "点 ≥ ", InpTier1ProfitMult, "×SL(", DoubleToString(slPoints, 1), "点)",
                     " 平仓", DoubleToString(closeLots, 2), "手 (", DoubleToString(InpTier1ClosePct * 100, 0), "%)",
                     " → 已解锁开第2仓权限(持久化)");
            }
         }
         continue;   // 本tick本仓只处理一档, 防跳档
      }

      // ---- 第2档: 利润 ≥ 2倍止损空间 → 平剩余仓位比例 ----
      if(g_tierSlots[slot].tierReached == 1 && profitPts >= InpTier2ProfitMult * slPoints)
      {
         // 重新读取当前剩余手数(第1档平仓后可能已变化)
         if(MySelectPosition(ticket))
            volume = PositionGetDouble(POSITION_VOLUME);
         double closeLots = NormalizeLot(volume * InpTier2ClosePct);
         if(closeLots > 0 && closeLots < volume)
         {
            if(g_trade.PositionClosePartial(ticket, closeLots))
            {
               g_tierSlots[slot].tierReached = 2;
               Print("🎯 分批止盈2档: [ticket=", ticket, "] 利润", DoubleToString(profitPts, 1),
                     "点 ≥ ", InpTier2ProfitMult, "×SL(", DoubleToString(slPoints, 1), "点)",
                     " 平仓", DoubleToString(closeLots, 2), "手 (剩余", DoubleToString(InpTier2ClosePct * 100, 0), "%)");
            }
         }
         continue;
      }

      // ---- 第3档: 利润 ≥ 3倍止损空间 → 平剩余全部 ----
      if(g_tierSlots[slot].tierReached == 2 && profitPts >= InpTier3ProfitMult * slPoints)
      {
         if(MySelectPosition(ticket))
            volume = PositionGetDouble(POSITION_VOLUME);
         double closeLots = NormalizeLot(volume * InpTier3ClosePct);
         if(closeLots > 0)
         {
            if(g_trade.PositionClosePartial(ticket, closeLots))
            {
               g_tierSlots[slot].tierReached = 3;
               Print("🎯 分批止盈3档(全平): [ticket=", ticket, "] 利润", DoubleToString(profitPts, 1),
                     "点 ≥ ", InpTier3ProfitMult, "×SL(", DoubleToString(slPoints, 1), "点)");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 查找持仓对应的分批止盈槽位 (返回槽位索引, -1=未找到)               |
//+------------------------------------------------------------------+
int FindTierSlot(ulong ticket)
{
   // 已存在 → 返回
   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      if(g_tierSlots[i].ticket == ticket)
         return i;
   }
   // 不存在 → 分配空槽
   for(int i = 0; i < TRAIL_SLOT_COUNT; i++)
   {
      if(g_tierSlots[i].ticket == 0)
      {
         g_tierSlots[i].ticket = ticket;
         return i;
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| 注册新开仓持仓到分批止盈槽位 (开仓成功后调用)                     |
//+------------------------------------------------------------------+
void RegisterTier(ulong ticket, double slPoints)
{
   if(!InpUseTieredTP) return;
   int slot = FindTierSlot(ticket);
   if(slot >= 0)
   {
      g_tierSlots[slot].ticket     = ticket;
      g_tierSlots[slot].slPoints   = slPoints;
      g_tierSlots[slot].tierReached = 0;
   }
}

//+------------------------------------------------------------------+
//| 更新趋势方向 (克罗: EMA34/89均线趋势判断)                          |
//| ★ v1.01修复: 位置一致性修正必须覆盖 g_trendDir==0 的情况           |
//|   旧代码只修正 ±1, 一旦CopyBuffer失败被置0, 方向永久卡死 → 永不入场|
//|   新逻辑: 数据就绪后无条件按快慢线相对位置更新方向                 |
//+------------------------------------------------------------------+
void UpdateTrendDirection()
{
   double fast[3], slow[3];
   // 数据未就绪 → 保持原方向(不再置0, 避免方向抖动)
   if(CopyBuffer(g_hFastMA, 0, 1, 3, fast) < 3) return;
   if(CopyBuffer(g_hSlowMA, 0, 1, 3, slow) < 3) return;

   // 金叉 (仅打日志用, 方向由下方无条件赋值保证)
   if(fast[0] > slow[0] && fast[1] <= slow[1])
   {
      if(g_trendDir != 1)
         Print("🔵 金叉! 快线=", DoubleToString(fast[0], 2), " > 慢线=", DoubleToString(slow[0], 2), " → 多头");
   }
   // 死叉
   else if(fast[0] < slow[0] && fast[1] >= slow[1])
   {
      if(g_trendDir != -1)
         Print("🔴 死叉! 快线=", DoubleToString(fast[0], 2), " < 慢线=", DoubleToString(slow[0], 2), " → 空头");
   }

   // ★ 关键修复: 无条件按当前均线位置更新方向 (覆盖 0/±1 所有状态)
   if(fast[0] > slow[0])
      g_trendDir = 1;
   else if(fast[0] < slow[0])
      g_trendDir = -1;
   else
      g_trendDir = 0;  // 两线相等(罕见), 保持等待
}

//+------------------------------------------------------------------+
//| 摆动低点查找: 从fromIdx向maxIdx(更早方向)找摆动低点               |
//| ★ v1.01核心修复: 原实现在"更新侧"找颈线, 方向反了导致W底/M顶永废 |
//|   MQL5索引: bar 0=当前, 索引越大=越早                              |
//|   L1(最近底) → 颈线N在 L1更早侧(idxN>idxL1) → L0在 N更早侧         |
//+------------------------------------------------------------------+
int FindSwingLow(int fromIdx, int maxIdx, int strength)
{
   for(int i = fromIdx; i <= maxIdx; i++)
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
   for(int i = fromIdx; i <= maxIdx; i++)
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
//| W底检测 (多头趋势) — 三种入场模式                                 |
//| 模式1 标准: 收盘突破颈线(N) + 缓冲 → 入场                         |
//| 模式2 激进①: 第二底L1未破第一底L0最低价 + 阳线收过第一底K线最高价 |
//| 模式3 激进②: 第二底L1跌破L0, 但InpAggrRecoverBars根内阳线收回     |
//| 返回: 1=标准 2=激进① 3=激进② 0=无信号                             |
//| 输出: slTarget 形态止损(止盈2:1由CheckEntry统一计算)              |
//+------------------------------------------------------------------+
int DetectWBottom(double &slTarget)
{
   double point = _Point;
   double open1  = iOpen(_Symbol, InpPatternTF, 1);
   double high1  = iHigh(_Symbol, InpPatternTF, 1);
   double low1   = iLow(_Symbol, InpPatternTF, 1);
   double close1 = iClose(_Symbol, InpPatternTF, 1);

   // 最近摆动低点L1: 距今至少2*strength+2根(右翼已确认)
   int minGap = InpSwingStrength * 2 + 2;
   int idxL1 = FindSwingLow(minGap, InpSwingLookback, InpSwingStrength);
   if(idxL1 <= 0) return 0;

   // 第一个底L0: 在L1更早侧(更大索引)找摆动低点
   int idxL0 = FindSwingLow(idxL1 + InpSwingStrength + 1, InpSwingLookback, InpSwingStrength);
   if(idxL0 <= 0) return 0;

   double L0 = iLow(_Symbol, InpPatternTF, idxL0);
   double L1 = iLow(_Symbol, InpPatternTF, idxL1);
   double H0 = iHigh(_Symbol, InpPatternTF, idxL0);  // 第一底最低K线的最高价

   // ========== 模式2: 激进① (第二底未破第一底最低价) ==========
   // ★ v1.09优化(防追单): 第二底回调深度 ≥ 最近一波反弹幅度的 InpAggrPullbackPct
   //   最近一波反弹: 第一底L0 → 两底之间摆动高点(颈线N) 的幅度 = N - L0
   //   第二底回调深度 = N - L1, 要求 N - L1 ≥ (N - L0) × InpAggrPullbackPct
   if(InpUseWBAggr1)
   {
      // 条件: L1 >= L0 (未破位) 且 阳线 且 收盘 > 第一底最低K线的最高价
      if(L1 >= L0 && close1 > open1 &&
         close1 > H0 + InpNeckBufferPts * point)
      {
         // 找两底之间的反弹高点(颈线N)作为反弹幅度基准
         int idxN = FindSwingHigh(idxL1 + InpSwingStrength + 1, idxL0 - InpSwingStrength - 1, InpSwingStrength);
         bool pullbackOk = true;
         if(idxN > 0)
         {
            double N = iHigh(_Symbol, InpPatternTF, idxN);
            double rallyAmp = N - L0;          // 最近一波反弹幅度
            double pullDepth = N - L1;         // 第二底回调深度
            if(rallyAmp > 0 && pullDepth < rallyAmp * InpAggrPullbackPct)
               pullbackOk = false;             // 回调不足50%, 有追单嫌疑 → 拒绝
         }
         // 未找到反弹高点时, 保守处理: 要求有颈线才算有效回调(防追单)
         else
            pullbackOk = false;

         if(pullbackOk)
         {
            slTarget = L0 - InpSLBufferPts * point;   // 止损=第一底最低点-20
            return 2;
         }
      }
   }

   // ========== 模式3: 激进② (第二底破位, 5根内阳线收回) ==========
   if(InpUseWBAggr2)
   {
      // 条件: L1 < L0 (破位) 且 两底间距≤RecoverBars 且 阳线 且 收盘>第一底K线最高价
      // ★ v1.05修复: 索引越大越早, 两底间隔 = idxL0 - idxL1
      if(L1 < L0 && (idxL0 - idxL1) <= InpAggrRecoverBars &&
         close1 > open1 && close1 > H0 + InpNeckBufferPts * point)
      {
         slTarget = L1 - InpSLBufferPts * point;   // 止损=第二底最低点-20
         return 3;
      }
   }

   // ========== 模式1: 标准 (突破颈线) ==========
   if(InpUseWBottom)
   {
      // 两底最小波幅过滤(标准模式需足够形态幅度)
      if(MathAbs(L1 - L0) < InpMinWavePts * point) return 0;

      // 颈线N: 两底之间的摆动高点 (idxL1 < idxN < idxL0)
      int idxN = FindSwingHigh(idxL1 + InpSwingStrength + 1, idxL0 - InpSwingStrength - 1, InpSwingStrength);
      if(idxN > 0)
      {
         double N = iHigh(_Symbol, InpPatternTF, idxN);
         // ★v1.13 颈线高于两底 ≥ InpNeckHeightMinPts(默认200点) — 形态高度不够不构成有效W底
         if(N > L0 + InpNeckHeightMinPts * point && N > L1 + InpNeckHeightMinPts * point)
         {
            // ★v1.22 ① 颈线年龄约束(防止"颈线太老"的假突破, 形态早已完成)
            if(idxN > InpMaxNeckAgeBars) return 0;

            // ★v1.11 有效突破: 该K线盘中最高价突破颈线位 + 收盘价依然收在颈线之上
            //   (排除假突破: 盘中刺穿但收盘回落颈线下方 = 无效)
            if(high1 > N && close1 > N)
            {
               // ★v1.22 ② 突破距离约束: bar1收盘距离颈线 ≤ 阈值(防止"已突破很久才入场"导致止损过大)
               if(close1 - N > InpMaxBreakoutDistPts * point) return 0;

               // ★v1.22 ③ 首次突破约束(可选): bar2最高 < 颈线, 保证 bar1 是首次突破(防"颈线之上震荡")
               if(InpRequireFirstBreak)
               {
                  double high2 = iHigh(_Symbol, InpPatternTF, 2);
                  if(high2 >= N) return 0;
               }

               // ★v1.13 止损回归v1.10旧逻辑: 整个W底形态最低点下方20点
               double lowest = MathMin(L0, L1);      // W底最低点
               slTarget = lowest - InpSLBufferPts * point;
               return 1;
            }
         }
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| M顶检测 (空头趋势) — 三种入场模式 (W底镜像)                      |
//| 模式1 标准: 收盘跌破颈线(N) - 缓冲 → 入场                        |
//| 模式2 激进①: 第二顶H1未破第一顶H0最高价 + 阴线收破第一顶K线最低价|
//| 模式3 激进②: 第二顶H1突破H0, 但InpAggrRecoverBars根内阴线收回    |
//| 返回: 1=标准 2=激进① 3=激进② 0=无信号                             |
//+------------------------------------------------------------------+
int DetectMTop(double &slTarget)
{
   double point = _Point;
   double open1  = iOpen(_Symbol, InpPatternTF, 1);
   double high1  = iHigh(_Symbol, InpPatternTF, 1);
   double low1   = iLow(_Symbol, InpPatternTF, 1);
   double close1 = iClose(_Symbol, InpPatternTF, 1);

   // 最近摆动高点H1: 距今至少2*strength+2根(右翼已确认)
   int minGap = InpSwingStrength * 2 + 2;
   int idxH1 = FindSwingHigh(minGap, InpSwingLookback, InpSwingStrength);
   if(idxH1 <= 0) return 0;

   // 第一个顶H0: 在H1更早侧(更大索引)找摆动高点
   int idxH0 = FindSwingHigh(idxH1 + InpSwingStrength + 1, InpSwingLookback, InpSwingStrength);
   if(idxH0 <= 0) return 0;

   double H0 = iHigh(_Symbol, InpPatternTF, idxH0);
   double H1 = iHigh(_Symbol, InpPatternTF, idxH1);
   double L0 = iLow(_Symbol, InpPatternTF, idxH0);   // 第一顶最高K线的最低价

   // ========== 模式2: 激进① (第二顶未破第一顶最高价) ==========
   // ★ v1.09优化(防追单): 第二顶反弹高度 ≥ 最近一波回调幅度的 InpAggrPullbackPct
   //   最近一波回调: 第一顶H0 → 两顶之间摆动低点(颈线N) 的幅度 = H0 - N
   //   第二顶反弹高度 = H1 - N, 要求 H1 - N ≥ (H0 - N) × InpAggrPullbackPct
   if(InpUseMTopAggr1)
   {
      // 条件: H1 <= H0 (未破位) 且 阴线 且 收盘 < 第一顶最高K线的最低价
      if(H1 <= H0 && close1 < open1 &&
         close1 < L0 - InpNeckBufferPts * point)
      {
         // 找两顶之间的回调低点(颈线N)作为回调幅度基准
         int idxN = FindSwingLow(idxH1 + InpSwingStrength + 1, idxH0 - InpSwingStrength - 1, InpSwingStrength);
         bool pullbackOk = true;
         if(idxN > 0)
         {
            double N = iLow(_Symbol, InpPatternTF, idxN);
            double pullAmp = H0 - N;           // 最近一波回调幅度
            double bounceH  = H1 - N;          // 第二顶反弹高度
            if(pullAmp > 0 && bounceH < pullAmp * InpAggrPullbackPct)
               pullbackOk = false;             // 反弹不足50%, 有追单嫌疑 → 拒绝
         }
         // 未找到回调低点时, 保守处理(防追单)
         else
            pullbackOk = false;

         if(pullbackOk)
         {
            slTarget = H0 + InpSLBufferPts * point;   // 止损=第一顶最高点+20
            return 2;
         }
      }
   }

   // ========== 模式3: 激进② (第二顶破位, 5根内阴线收回) ==========
   if(InpUseMTopAggr2)
   {
      // 条件: H1 > H0 (破位) 且 两顶间距≤RecoverBars 且 阴线 且 收盘<第一顶K线最低价
      // ★ v1.05修复: 索引越大越早, 两顶间隔 = idxH0 - idxH1
      if(H1 > H0 && (idxH0 - idxH1) <= InpAggrRecoverBars &&
         close1 < open1 && close1 < L0 - InpNeckBufferPts * point)
      {
         slTarget = H1 + InpSLBufferPts * point;   // 止损=第二顶最高点+20
         return 3;
      }
   }

   // ========== 模式1: 标准 (跌破颈线) ==========
   if(InpUseMTop)
   {
      // 两顶最小波幅过滤(标准模式需足够形态幅度)
      if(MathAbs(H1 - H0) < InpMinWavePts * point) return 0;

      // 颈线N: 两顶之间的摆动低点 (idxH1 < idxN < idxH0)
      int idxN = FindSwingLow(idxH1 + InpSwingStrength + 1, idxH0 - InpSwingStrength - 1, InpSwingStrength);
      if(idxN > 0)
      {
         double N = iLow(_Symbol, InpPatternTF, idxN);
         // ★v1.13 颈线低于两顶 ≥ InpNeckHeightMinPts(默认200点) — 形态深度不够不构成有效M顶
         if(N < H0 - InpNeckHeightMinPts * point && N < H1 - InpNeckHeightMinPts * point)
         {
            // ★v1.22 ① 颈线年龄约束(防止"颈线太老"的假跌破)
            if(idxN > InpMaxNeckAgeBars) return 0;

            // ★v1.11 有效突破: 该K线盘中最低价跌破颈线位 + 收盘价依然收在颈线之下
            //   (排除假突破: 盘中刺穿但收盘收回颈线上方 = 无效)
            if(low1 < N && close1 < N)
            {
               // ★v1.22 ② 突破距离约束: bar1收盘距离颈线 ≤ 阈值(防止"已跌破很久才入场"导致止损过大)
               if(N - close1 > InpMaxBreakoutDistPts * point) return 0;

               // ★v1.22 ③ 首次跌破约束(可选): bar2最低 > 颈线, 保证 bar1 是首次跌破(防"颈线之下震荡")
               if(InpRequireFirstBreak)
               {
                  double low2 = iLow(_Symbol, InpPatternTF, 2);
                  if(low2 <= N) return 0;
               }

               // ★v1.13 止损回归v1.10旧逻辑: 整个M顶形态最高点上方20点
               double highest = MathMax(H0, H1);   // M顶最高点
               slTarget = highest + InpSLBufferPts * point;
               return 1;
            }
         }
      }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| ★v1.22 顺势关键位突破 (替代原"窄幅平台"逻辑)                      |
//| 多头: bar1收盘 > 前N根K线最高(阻力位)+缓冲 → 突破开多               |
//| 空头: bar1收盘 < 前N根K线最低(支撑位)+缓冲 → 跌破开空               |
//| SL: 形态底部/顶部 ± InpSLBufferPts 缓冲(20点)                     |
//+------------------------------------------------------------------+
int DetectPlatform()
{
   double point = _Point;
   double hi = DBL_MIN, lo = DBL_MAX;
   for(int i = 2; i <= InpPlatLookback; i++)
   {
      double h = iHigh(_Symbol, InpPatternTF, i);
      double l = iLow(_Symbol, InpPatternTF, i);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
   }

   double close1 = iClose(_Symbol, InpPatternTF, 1);

   // 多头向上突破: bar1收盘 > 前N根K线最高 + 缓冲
   if(close1 > hi + InpNeckBufferPts * point) return 1;
   // 空头向下突破: bar1收盘 < 前N根K线最低 - 缓冲
   if(close1 < lo - InpNeckBufferPts * point) return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| ★v2.02 回调入场: 2B法则 (顺大趋势等回调企稳, 防追高追空)          |
//| 理念: 顺大趋势 → 逆小回调 → 2B/双底企稳后入场                     |
//| 多头(空头镜像):                                                   |
//|   1. 找回调起点波段高点 H → 回调第一个低点 L1 (Swing Low)          |
//|      ★v2.02 回调板块专用 PB_STRENGTH=2 (左右各2根确认)            |
//|   2. 回调深度: (H-L1) ≥ (H-L0)×PctMin (防追单)                    |
//|   3. L1 之后 Inp2BMaxBars 根内找最低点 L2                          |
//|      ★v2.01 总窗口: L1出现后 ≤34根内必须完成"跌破+收回"全程       |
//|      场景A 标准2B: L2跌破L1 → 当前收盘收回L1上方 → 下根开盘做多    |
//|      场景B 双底企稳: L2未破L1 且 |L2-L1|≤Inp2BMaxGapPts + 企稳阳线 |
//| 止损: 两低点中最低者 - 20点; 止盈: CheckEntry统一 2:1             |
//| 返回: 1=BUY  -1=SELL  0=无信号                                    |
//| 输出: slTarget 止损价, name 信号名                                 |
//+------------------------------------------------------------------+
int DetectPullbackEntry(double &slTarget, string &name)
{
   if(!InpUsePullbackEntry) return 0;
   if(g_trendDir == 0)      return 0;

   double point  = _Point;
   double open1  = iOpen(_Symbol, InpPatternTF, 1);
   double high1  = iHigh(_Symbol, InpPatternTF, 1);
   double low1   = iLow(_Symbol, InpPatternTF, 1);
   double close1 = iClose(_Symbol, InpPatternTF, 1);

   bool   isBull = (g_trendDir == 1);
   // ★v2.02 回调板块专用: 摆动确认数=2根(左右各2根), minGap=5, 避开bar0-4未确认K线
   //   与全局 InpSwingStrength=3 解耦(W底/M顶/平台仍用3根确认)
   const int PB_STRENGTH = 2;
   int    minGap = PB_STRENGTH * 2 + 1;

   // ============================================================
   // 多头: 2B法则回调入场
   // ============================================================
   if(isBull)
   {
      // --- 1. 找回调起点波段高点 H (最近Swing High) ---
      int idxH = FindSwingHigh(minGap, InpPullbackLookback, PB_STRENGTH);
      if(idxH <= minGap + PB_STRENGTH + 1) return 0;   // 距当前太近, 无空间找L1/L2
      double H = iHigh(_Symbol, InpPatternTF, idxH);

      // --- 2. 找前一波段起点 L0 (H 之前更早的Swing Low) 用于回调深度 ---
      int idxL0 = FindSwingLow(idxH + PB_STRENGTH + 1, InpPullbackLookback, PB_STRENGTH);
      if(idxL0 <= 0) return 0;
      double L0 = iLow(_Symbol, InpPatternTF, idxL0);
      double waveAmp = H - L0;
      if(waveAmp <= 0) return 0;

      // --- 3. 找回调第一个低点 L1 (H 之后最近的Swing Low) ---
      int idxL1 = FindSwingLow(minGap, idxH - PB_STRENGTH - 1, PB_STRENGTH);
      if(idxL1 <= 0) return 0;
      // ★v2.01 总窗口: L1出现后 Inp2BMaxBars 根内必须完成"跌破+收回"
      //   bar1(确认K线)距L1超过窗口 → 信号过期(跌破+收回全程超出34根)
      if(idxL1 - 1 > Inp2BMaxBars) return 0;
      double L1 = iLow(_Symbol, InpPatternTF, idxL1);

      // --- 4. 回调深度校验: 回调 ≥ 前一波段的 InpPullbackPctMin (防追单) ---
      double pullDepth = H - L1;
      if(pullDepth < waveAmp * InpPullbackPctMin) return 0;

      // --- 5. 找第二个低点 L2: L1 之后(更近方向) Inp2BMaxBars 根内最低点 ---
      double L2  = DBL_MAX;
      int    idxL2 = -1;
      int    scanTo = MathMax(1, idxL1 - Inp2BMaxBars);
      for(int i = idxL1 - 1; i >= scanTo; i--)
      {
         double l = iLow(_Symbol, InpPatternTF, i);
         if(l < L2) { L2 = l; idxL2 = i; }
      }
      if(idxL2 < 0 || L2 == DBL_MAX) return 0;

      // --- 场景A: 标准2B — L2跌破L1 + 当前收盘收回L1上方 → 做多 ---
      if(L2 < L1 && close1 > L1)
      {
         slTarget = MathMin(L1, L2) - InpSLBufferPts * point;
         name = "回调2B-破位收回(多)";
         return 1;
      }

      // --- 场景B: 双底企稳 — L2未破L1 + 价差≤200点 + 企稳阳线 → 做多 ---
      if(L2 >= L1 && (L2 - L1) <= Inp2BMaxGapPts * point)
      {
         double body = MathAbs(close1 - open1);
         double fullRange = high1 - low1;
         if(fullRange <= 0) return 0;
         if(close1 <= open1) return 0;                                    // 需收阳
         if(close1 <= L2)    return 0;                                    // 收盘需站上最近低点
         if(body / fullRange < InpPullbackStabBodyPct) return 0;          // 排除十字星
         slTarget = MathMin(L1, L2) - InpSLBufferPts * point;
         name = "回调2B-双底企稳(多)";
         return 1;
      }
   }
   else // 空头镜像
   {
      // --- 1. 找回调起点波段低点 L (最近Swing Low) ---
      int idxL = FindSwingLow(minGap, InpPullbackLookback, PB_STRENGTH);
      if(idxL <= minGap + PB_STRENGTH + 1) return 0;
      double L = iLow(_Symbol, InpPatternTF, idxL);

      // --- 2. 找前一波段起点 H0 (L 之前更早的Swing High) ---
      int idxH0 = FindSwingHigh(idxL + PB_STRENGTH + 1, InpPullbackLookback, PB_STRENGTH);
      if(idxH0 <= 0) return 0;
      double H0 = iHigh(_Symbol, InpPatternTF, idxH0);
      double waveAmp = H0 - L;
      if(waveAmp <= 0) return 0;

      // --- 3. 找回调第一个高点 H1 (L 之后最近的Swing High) ---
      int idxH1 = FindSwingHigh(minGap, idxL - PB_STRENGTH - 1, PB_STRENGTH);
      if(idxH1 <= 0) return 0;
      // ★v2.01 总窗口: H1出现后 Inp2BMaxBars 根内必须完成"突破+收回"
      if(idxH1 - 1 > Inp2BMaxBars) return 0;
      double H1 = iHigh(_Symbol, InpPatternTF, idxH1);

      // --- 4. 回调深度校验: 反弹 ≥ 前一波段的 InpPullbackPctMin (防追单) ---
      double pullDepth = H1 - L;
      if(pullDepth < waveAmp * InpPullbackPctMin) return 0;

      // --- 5. 找第二个高点 H2: H1 之后(更近方向) Inp2BMaxBars 根内最高点 ---
      double H2  = DBL_MIN;
      int    idxH2 = -1;
      int    scanTo = MathMax(1, idxH1 - Inp2BMaxBars);
      for(int i = idxH1 - 1; i >= scanTo; i--)
      {
         double h = iHigh(_Symbol, InpPatternTF, i);
         if(h > H2) { H2 = h; idxH2 = i; }
      }
      if(idxH2 < 0 || H2 == DBL_MIN) return 0;

      // --- 场景A: 标准2B — H2突破H1 + 当前收盘收回H1下方 → 做空 ---
      if(H2 > H1 && close1 < H1)
      {
         slTarget = MathMax(H1, H2) + InpSLBufferPts * point;
         name = "回调2B-破位收回(空)";
         return -1;
      }

      // --- 场景B: 双顶企稳 — H2未破H1 + 价差≤200点 + 企稳阴线 → 做空 ---
      if(H2 <= H1 && (H1 - H2) <= Inp2BMaxGapPts * point)
      {
         double body = MathAbs(close1 - open1);
         double fullRange = high1 - low1;
         if(fullRange <= 0) return 0;
         if(close1 >= open1) return 0;                                    // 需收阴
         if(close1 >= H2)    return 0;                                    // 收盘需跌破最近高点
         if(body / fullRange < InpPullbackStabBodyPct) return 0;          // 排除十字星
         slTarget = MathMax(H1, H2) + InpSLBufferPts * point;
         name = "回调2B-双顶企稳(空)";
         return -1;
      }
   }

   return 0;
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
//| 主入场检查 (新M1 K线开盘时调用)                                   |
//| ★ v1.05重构: 只顺趋势方向 + 3种形态(平台突破/W底/M顶)三模式       |
//|   - EMA55/MA233金叉=多头趋势只做多, 死叉=空头趋势只做空           |
//|   - W底: 标准(破颈线)/激进①(未破位)/激进②(破位5根内收回)        |
//|   - M顶: 镜像                                                      |
//|   - 平台突破: 只做顺趋势方向的突破(反向突破不交易)                |
//|   - 每笔强制 SL(形态极值) + TP(2×SL, 盈亏比2:1)                   |
//+------------------------------------------------------------------+
void CheckEntry()
{
   // 1. 风控检查 (仅控制是否开新仓) ★v1.10: 细分拦截原因, 诊断模式打印详情
   if(!g_Common.IsTradingAllowed())
   {
      if(InpDiagnosticLog)
      {
         string reason = "未知";
         if(!g_Common.IsTradeTimeAllowed())
            reason = "交易时间外(北京时间窗口外)";
         else if(!g_Common.CheckSpreadLimit())
            reason = "点差超标(当前>上限" + IntegerToString(InpMaxSpreadPoints) + "点)";
         else if(!g_Common.CheckDailyLossLimit())
            reason = "当日亏损已达上限";
         else if(!g_Common.CheckConsecutiveLossPause())
            reason = "连续亏损暂停中";
         Print("🩺 诊断: 开仓被风控拦截 - ", reason,
               " | 服务器时间=", TimeToString(TimeCurrent()),
               " | 北京时间=", TimeToString(BeijingTimeNow()),
               " | 点差=", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), "点");
      }
      return;
   }

   // 2. ★v1.18 持仓上限彻底修复: 双仓必须先走过1×SL利润(分批止盈第1档触发)
// ★v1.20 持仓上限彻底修复(独立于所有参数, 不依赖InpUseTieredTP):
   //   实际允许持仓数 = g_anyTier1Triggered ? InpMaxPositions : 1
   int effectiveMaxPos = g_anyTier1Triggered ? InpMaxPositions : 1;
   if(CountPositions() >= effectiveMaxPos)
   {
      Print("⛔ 分批止盈冷却拦截! 已有持仓=", CountPositions(),
            " 但分批止盈第1档尚未触发, 实际单仓上限=", effectiveMaxPos,
            " | InpUseTieredTP=", (InpUseTieredTP ? "true" : "false"),
            " | g_anyTier1Triggered=", (g_anyTier1Triggered ? "true" : "false"),
            " | GV=", g_gvTier1Fired, " ", (GlobalVariableCheck(g_gvTier1Fired) ? DoubleToString(GlobalVariableGet(g_gvTier1Fired), 0) : "N/A"));
      return;
   }

   // 3. 趋势方向更新 (克罗: EMA55/MA233顺势) — 只顺趋势方向
   UpdateTrendDirection();
   if(InpUseTrendFilter && g_trendDir == 0)
   {
      if(InpDiagnosticLog)
         Print("🩺 诊断: 趋势方向=0(EMA55与MA233相等或数据未就绪) 暂不开仓",
               " | 北京时间=", TimeToString(BeijingTimeNow()));
      return;
   }

   // ★ 方向: 多头趋势只做多, 空头趋势只做空 (开关关闭时双向)
   bool allowLong  = (!InpUseTrendFilter) || (g_trendDir >= 0);
   bool allowShort = (!InpUseTrendFilter) || (g_trendDir <= 0);

   // 4. 形态识别 (输出形态止损slTarget, 止盈2:1统一计算)
   double slTarget = 0;
   ENUM_ORDER_TYPE signal = WRONG_VALUE;
   string signalName = "";

   // ===== W底 (多头趋势) — 标准/激进①/激进② =====
   if(allowLong)
   {
      int mode = DetectWBottom(slTarget);
      if(mode == 1)      { signal = ORDER_TYPE_BUY; signalName = "W底-标准(破颈线)"; }
      else if(mode == 2) { signal = ORDER_TYPE_BUY; signalName = "W底-激进①(未破位)"; }
      else if(mode == 3) { signal = ORDER_TYPE_BUY; signalName = "W底-激进②(破位收回)"; }
   }

   // ===== M顶 (空头趋势) — 镜像 =====
   if(signal == WRONG_VALUE && allowShort)
   {
      int mode = DetectMTop(slTarget);
      if(mode == 1)      { signal = ORDER_TYPE_SELL; signalName = "M顶-标准(破颈线)"; }
      else if(mode == 2) { signal = ORDER_TYPE_SELL; signalName = "M顶-激进①(未破位)"; }
      else if(mode == 3) { signal = ORDER_TYPE_SELL; signalName = "M顶-激进②(破位收回)"; }
   }

   // ===== 顺势关键位突破 (★v1.22: 替代原"窄幅平台"逻辑) =====
   if(signal == WRONG_VALUE && InpUsePlatform)
   {
      int platDir = DetectPlatform();
      // 多头趋势: 只做向上突破(platDir=1), 向下突破不交易
      if(platDir == 1 && allowLong)
      {
         // SL: 形态底部下方20点 (前N根K线的最低点 - 缓冲)
         double lo = DBL_MAX;
         for(int i = 2; i <= InpPlatLookback; i++)
         {
            double l = iLow(_Symbol, InpPatternTF, i);
            if(l < lo) lo = l;
         }
         slTarget = lo - InpSLBufferPts * _Point;
         signal = ORDER_TYPE_BUY;
         signalName = "顺势关键位突破(多)";
      }
      // 空头趋势: 只做向下突破(platDir=-1), 向上突破不交易
      else if(platDir == -1 && allowShort)
      {
         // SL: 形态顶部上方20点 (前N根K线的最高点 + 缓冲)
         double hi = DBL_MIN;
         for(int i = 2; i <= InpPlatLookback; i++)
         {
            double h = iHigh(_Symbol, InpPatternTF, i);
            if(h > hi) hi = h;
         }
         slTarget = hi + InpSLBufferPts * _Point;
         signal = ORDER_TYPE_SELL;
         signalName = "顺势关键位突破(空)";
      }
   }

   // ============================================================
   // ★v2.02 回调入场: 2B法则 (摆动确认2根 + 场景A标准2B破位收回 / 场景B双底企稳)
   //   v2.01 总窗口: 跌破+收回全程限 L1 后 Inp2BMaxBars 根内
   //   优先级: 形态突破(W底/M顶/平台) > 回调入场(补充)
   //   形态未触发时, 才评估回调 (避免重复信号)
   // ============================================================
   if(signal == WRONG_VALUE && InpUsePullbackEntry)
   {
      int pb = DetectPullbackEntry(slTarget, signalName);
      if(pb == 1)       signal = ORDER_TYPE_BUY;
      else if(pb == -1) signal = ORDER_TYPE_SELL;
   }

   // 5. 无信号
   if(signal == WRONG_VALUE)
   {
      // ★v1.10 诊断快照: 打印当前市场数据, 便于对比多终端数据差异
      if(InpDiagnosticLog)
      {
         double fast[1], slow[1];
         CopyBuffer(g_hFastMA, 0, 1, 1, fast);
         CopyBuffer(g_hSlowMA, 0, 1, 1, slow);
         Print("🩺 诊断: 形态未触发 | 趋势=", (g_trendDir == 1 ? "多头" : (g_trendDir == -1 ? "空头" : "0")),
               " EMA55=", DoubleToString(fast[0], 2),
               " MA233=", DoubleToString(slow[0], 2),
               " | bar1 O=", DoubleToString(iOpen(_Symbol, InpPatternTF, 1), 2),
               " H=", DoubleToString(iHigh(_Symbol, InpPatternTF, 1), 2),
               " L=", DoubleToString(iLow(_Symbol, InpPatternTF, 1), 2),
               " C=", DoubleToString(iClose(_Symbol, InpPatternTF, 1), 2),
               " | 北京时间=", TimeToString(BeijingTimeNow()));
      }
      return;
   }

   // 6. 信号去重: 同一形态bar只开一单 (iTime时间戳唯一标识)
   datetime sigBarTime = iTime(_Symbol, InpPatternTF, 1);
   if(sigBarTime == g_lastEntryBarTime)
      return;

   // ★v1.14 平仓冷却: 在该根K线上刚平仓 → 决不允许再开仓
   //   平仓后 InpCloseCooldownBars 根K线内禁止开新仓(默认1=仅平仓所在K线)
   if(InpUseCloseCooldown && g_lastCloseBarTime != 0)
   {
      long barsSinceClose = (long)((sigBarTime - g_lastCloseBarTime) / PeriodSeconds(InpPatternTF));
      if(barsSinceClose < InpCloseCooldownBars)
      {
         if(InpDiagnosticLog)
            Print("🩺 诊断: 平仓冷却拦截! 距平仓仅", barsSinceClose,
                  "根K线(<", InpCloseCooldownBars, ") 同根K线平仓后禁止再开仓 | ",
                  "信号=[", signalName, "] ", (signal == ORDER_TYPE_BUY ? "BUY" : "SELL"));
         return;
      }
   }

   // 7. 执行开仓 (v1.04: 强制SL+TP, TP=盈亏比×SL区间)
   double entryPrice = (signal == ORDER_TYPE_BUY)
                       ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 止损点数(用于通用模块手数计算)
   double slPoints = MathAbs(entryPrice - slTarget) / _Point;
   if(slPoints < 10) slPoints = 10;   // 最小SL保护(防手数过大)

   // ★ 风控: 止损空间过大则拒绝开仓 (v1.08)
   //   止损 ≥ InpMaxSLPoints(默认1500点=15美金) 说明形态波幅过大, 风险不可控
   if(InpUseMaxSLPoints && slPoints >= InpMaxSLPoints)
   {
      Print("⛔ 风控拦截! [", signalName, "] ", (signal == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " 止损点数=", DoubleToString(slPoints, 1),
            " ≥ 上限 ", InpMaxSLPoints, "点, 止损过大不开仓");
      return;
   }

   // ★v1.14 盈亏比可调: TP = 入场 ± InpRewardRiskRatio × SL区间 (默认2:1, 可3:1/5:1等)
   // ★v1.15 启用分批止盈时: TP放远到第3档倍数位置, 由分批止盈主导出场(避免固定TP抢先全平)
   double tpPoints = InpRewardRiskRatio * slPoints;
   if(InpUseTieredTP)
   {
      double maxMult = InpTier3ProfitMult;
      if(maxMult < InpRewardRiskRatio) maxMult = InpRewardRiskRatio;
      tpPoints = maxMult * slPoints;
   }
   double tpTarget = (signal == ORDER_TYPE_BUY)
                     ? entryPrice + tpPoints * _Point
                     : entryPrice - tpPoints * _Point;

   // 开仓 (手数按形态SL点数计算, 风险%模式正确; SL/TP强制带入)
   if(g_Common.OpenPosition(signal, entryPrice, slPoints, tpPoints))
   {
      g_lastEntryBarTime = sigBarTime;

      // 精确修正形态SL/TP (金刚经: 止损设在形态极值绝对价格, 止盈按盈亏比)
      ulong ticket = FindLastPositionTicket();
      if(ticket != 0)
      {
         SetExactSLTP(ticket, slTarget, tpTarget);
         // ★v1.15 注册分批止盈槽位 (记录该单止损空间, 作为1/2/3倍利润基准)
         RegisterTier(ticket, slPoints);
         // ★v1.20 开仓成功后重置触发状态: 每个新仓位需要独立走到1×SL才能开下一仓
         g_anyTier1Triggered = false;
         if(GlobalVariableCheck(g_gvTier1Fired))
            GlobalVariableSet(g_gvTier1Fired, 0.0);
      }

      Print("🚀 开仓! [", signalName, "] ", (signal == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " 形态SL=", DoubleToString(slTarget, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
            " 止损点数=", DoubleToString(slPoints, 1),
            " 止盈点数=", DoubleToString(tpPoints, 1),
            " (盈亏比", DoubleToString(InpRewardRiskRatio, 1), ":1)",
            InpUseTieredTP ? StringFormat(" | 分批止盈: %.0f%%/%.0f%%/%.0f%% @ %.0fx/%.0fx/%.0fxSL",
                InpTier1ClosePct * 100, InpTier2ClosePct * 100, InpTier3ClosePct * 100,
                InpTier1ProfitMult, InpTier2ProfitMult, InpTier3ProfitMult) : "");
   }
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
//| 精确设置形态SL/TP (金刚经: 止损设在形态极值绝对价格)               |
//| ★ v1.04: 每笔强制带SL+TP, TP = 入场价 ± 2×SL区间 (盈亏比2:1)      |
//|   不再受 InpUseFixedStopLoss/InpUseFixedTakeProfit 开关控制        |
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

   // ★v1.14 强制盈亏比止盈: 若外部未提供tpTarget, 按入场价±InpRewardRiskRatio×SL距离计算
   if(tpTarget <= 0)
   {
      double slDist = MathAbs(openPrice - slTarget);
      tpTarget = (posType == POSITION_TYPE_BUY)
                 ? openPrice + InpRewardRiskRatio * slDist
                 : openPrice - InpRewardRiskRatio * slDist;
   }

   double newSL = currentSL;
   double newTP = currentTP;

   // 形态SL: 若当前SL未设置或比形态位差, 则修正 (BUY)
   if(posType == POSITION_TYPE_BUY)
   {
      if(currentSL == 0 || currentSL < slTarget - point)
         newSL = slTarget;
   }
   else // SELL
   {
      if(currentSL == 0 || currentSL > slTarget + point)
         newSL = slTarget;
   }

   // ★ v1.04: TP强制设置(2:1), 与开关无关
   if(tpTarget > 0)
      newTP = tpTarget;

   // 校验: SL/TP不能等于0且方向正确
   if(newSL <= 0 || newTP <= 0)
      return;

   // 方向校验: BUY的TP必须>SL, SELL的TP必须<SL (防反向)
   if(posType == POSITION_TYPE_BUY && newTP <= newSL)
      return;
   if(posType == POSITION_TYPE_SELL && newTP >= newSL)
      return;

   if(newSL != currentSL || newTP != currentTP)
   {
      if(!g_trade.PositionModify(ticket, newSL, newTP))
         PrintFormat("❌ 形态SL/TP修正失败 ticket=%I64u retcode=%u (%s)",
                     ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| 按ticket选择持仓 (自定义, 避免与MQL5内置PositionSelectByTicket重名)|
//+------------------------------------------------------------------+
bool MySelectPosition(ulong ticket)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == ticket)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 交易事务事件 (用于同Bar平仓保护与状态清理)                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // ★v1.21 平仓冷却: 检测平仓交易(DEAL_ENTRY_OUT), 记录平仓所在K线时间
   //   之后 CheckEntry 中如果同根K线再次触发信号 → 禁止开仓
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.deal != 0 && HistoryDealSelect(trans.deal))
      {
         long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         // ★v1.21关键修复: 排除历史回放!
         //   MT5在EA加载时会对账户中所有历史成交回放DEAL_ADD事件,
         //   若不加时间过滤, 历史平仓单会把g_lastCloseBarTime写成当前时间
         //   → 冷却检查barsSinceClose=0永远拦截 → EA永不入场!
         datetime dealTime = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
         bool isRecent = (dealTime > 0 && (TimeCurrent() - dealTime) <= 30);
         // 本EA的平仓交易(DEAL_ENTRY_OUT = 平仓单) 且是近期真实发生的
         if(isRecent && magic == g_magic && entry == DEAL_ENTRY_OUT)
         {
            // ★v1.21修复: 记录平仓时当前K线(bar0)时间戳, 而非bar1(已收盘)
            g_lastCloseBarTime = iTime(_Symbol, InpPatternTF, 0);
            if(InpDiagnosticLog)
               Print("🩺 诊断: 平仓冷却触发 | 平仓K线(bar0)=", TimeToString(g_lastCloseBarTime),
                     " | dealTime=", TimeToString(dealTime));
         }
      }
   }
}
//+------------------------------------------------------------------+
