//+------------------------------------------------------------------+
//|                                            EA交易助手_快捷平仓.mq5 |
//|                                           Senior Developer        |
//|                                                                   |
//|  功能: MT5图表右下角快捷平仓管理                                   |
//|  包含4个按键: 全平仓 | ½平仓 | ⅓平仓 | ¼平仓                    |
//|                                                                   |
//|  使用说明:                                                        |
//|  1. 将EA加载到任意图表                                             |
//|  2. 右下角自动出现4个平仓按钮                                     |
//|  3. 点击对应按钮即可按比例平仓当前品种持仓                         |
//|                                                                   |
//|  注意事项:                                                        |
//|  - 仅操作当前图表品种的持仓                                       |
//|  - 部分平仓时手数自动向下取整到合法步长                           |
//|  - 如果计算出的平仓手数为0则不执行                                |
//+------------------------------------------------------------------+
#property copyright "Senior Developer"
#property version   "1.00"
#property description "MT5交易助手 - 快捷平仓管理"
#property description "右下角四键平仓: 全平仓 | ½平仓 | ⅓平仓 | ¼平仓"
#property description "仅操作当前图表品种,支持多个持仓按比例平仓"
#property description "部分平仓手数自动向下取整到最小步长"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 输入参数                                                         |
//+------------------------------------------------------------------+
input group   "=== ★ 界面设置 ==="
input int     InpBtnWidth        = 118;             // 按钮宽度(像素)
input int     InpBtnHeight       = 55;              // 按钮高度(像素)
input int     InpBtnGap          = 4;               // 按钮间距(像素)
input int     InpMarginRight     = 135;              // 右边距(像素) - 建议80-100避开右侧价格栏
input int     InpMarginBottom    = 68;              // 底部边距(像素) - 建议50-80避开底部时间轴
input color   InpFontColor       = clrWhite;        // 文字颜色

input group   "=== ★ 颜色设置(BGR格式) ==="
input color   InpColorAll        = 0x3333CC;        // 全平仓(红)
input color   InpHalfColor       = 0x3399FF;        // ½平仓(橙)
input color   InpThirdColor      = 0xFF6600;        // ⅓平仓(蓝)
input color   InpQuarterColor    = 0x33CC33;        // ¼平仓(绿)
input color   InpDisableColor    = 0x555555;        // 禁用灰色

input group   "=== ★ 交易设置 ==="
input int     InpDeviation       = 50;              // 滑点(点数)
input bool    InpShowConfirm     = false;           // 显示确认弹窗

//+------------------------------------------------------------------+
//| 按钮名称常量                                                     |
//+------------------------------------------------------------------+
#define PREFIX       "TradeHelper_"
#define BTN_CLOSEALL PREFIX + "CloseAll"
#define BTN_HALF     PREFIX + "Half"
#define BTN_THIRD    PREFIX + "Third"
#define BTN_QUARTER  PREFIX + "Quarter"

//+------------------------------------------------------------------+
//| 按钮索引                                                         |
//+------------------------------------------------------------------+
enum ENUM_BTN_INDEX
{
   IDX_CLOSEALL = 0,   // 全平仓
   IDX_HALF,           // ½平仓
   IDX_THIRD,          // ⅓平仓
   IDX_QUARTER,        // ¼平仓
   IDX_TOTAL           // 按钮总数
};

//+------------------------------------------------------------------+
//| 按钮文字                                                         |
//+------------------------------------------------------------------+
string g_btnLabels[IDX_TOTAL] =
{
   "全平仓",
   "½ 平仓",
   "⅓ 平仓",
   "¼ 平仓"
};

color g_btnColors[IDX_TOTAL];

//+------------------------------------------------------------------+
//| 持仓信息结构体(全局定义,兼容MQL5规范)                              |
//+------------------------------------------------------------------+
struct PosInfo
{
   ulong  ticket;
   double volume;
};

//+------------------------------------------------------------------+
//| 全局变量                                                         |
//+------------------------------------------------------------------+
CTrade      m_trade;
int         g_timerId       = -1;

//+------------------------------------------------------------------+
//| 初始化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 初始化按钮颜色
   g_btnColors[IDX_CLOSEALL] = InpColorAll;
   g_btnColors[IDX_HALF]     = InpHalfColor;
   g_btnColors[IDX_THIRD]    = InpThirdColor;
   g_btnColors[IDX_QUARTER]  = InpQuarterColor;

   //--- 交易设置
   m_trade.SetExpertMagicNumber(0);      // 不限制MagicNumber,操作所有EA的持仓
   m_trade.SetDeviationInPoints(InpDeviation);
   m_trade.SetAsyncMode(false);

   //--- 创建按钮
   if(!CreateButtons())
   {
      Print("❌ 创建按钮失败");
      return INIT_FAILED;
   }

   //--- 创建定时器(每秒刷新按钮状态)
   g_timerId = EventSetMillisecondTimer(1000);
   if(g_timerId < 0)
      Print("⚠️ 定时器创建失败,按钮状态不会自动刷新");

   Print("╔══════════════════════════════════════╗");
   Print("║     EA交易助手 - 快捷平仓 v1.00      ║");
   Print("╠══════════════════════════════════════╣");
   Print("║ 品种: ", _Symbol);
   Print("║ 按钮: 全平仓 | ½ | ⅓ | ¼            ║");
   Print("╚══════════════════════════════════════╝");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 反初始化                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- 删除定时器
   if(g_timerId >= 0)
      EventKillTimer();

   //--- 删除所有按钮
   DeleteButtons();

   if(reason != REASON_CHARTCHANGE && reason != REASON_PROGRAM)
   {
      Print("📌 EA已停止,原因代码: ", reason);
   }
}

//+------------------------------------------------------------------+
//| 创建按钮                                                         |
//+------------------------------------------------------------------+
bool CreateButtons()
{
   //--- CORNER_RIGHT_LOWER + ANCHOR_RIGHT_LOWER:
   //    XDISTANCE = 距右边界的像素, YDISTANCE = 距底边界的像素
   //    田字形 2×2 排列(右下角为原点):
   //       ¼平仓(右下)   ⅓平仓(左下)
   //       ½平仓(右上)   全平仓(左上)
   for(int idx = 0; idx < IDX_TOTAL; idx++)
   {
      int col     = idx % 2;                                        // 0=右列, 1=左列
      int row     = idx / 2;                                        // 0=下行, 1=上行
      int btnX    = InpMarginRight + col * (InpBtnWidth + InpBtnGap);
      int btnY    = InpMarginBottom + row * (InpBtnHeight + InpBtnGap);
      string name = GetBtnName(idx);

      //--- 获取当前持仓手数,用于全平仓按钮显示
      double totalVol = GetTotalVolume();
      string label    = g_btnLabels[idx];

      //--- 全平仓按钮显示总手数
      if(idx == IDX_CLOSEALL)
         label += " " + DoubleToString(totalVol, 2);

      if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
      {
         Print("❌ 创建按钮[", name, "]失败: ", GetLastError());
         return false;
      }

      //--- CORNER_RIGHT_LOWER + ANCHOR_RIGHT_LOWER:
      //    XDISTANCE = 右边距, YDISTANCE = 底边距
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, btnX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, btnY);
      ObjectSetInteger(0, name, OBJPROP_XSIZE,     InpBtnWidth);
      ObjectSetInteger(0, name, OBJPROP_YSIZE,     InpBtnHeight);
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_RIGHT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,    ANCHOR_RIGHT_LOWER);
      ObjectSetString(0,  name, OBJPROP_TEXT,      label);
      ObjectSetString(0,  name, OBJPROP_FONT,      "Arial");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  11);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     InpFontColor);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,   g_btnColors[idx]);
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrNONE);
      ObjectSetInteger(0, name, OBJPROP_BACK,      false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,    false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER,    0);

      //--- 根据是否有持仓设置初始状态
      bool hasPos = (totalVol > 0);
      ObjectSetInteger(0, name, OBJPROP_STATE, false);    // 未按下
      SetBtnState(name, idx, hasPos);
   }

   return true;
}

//+------------------------------------------------------------------+
//| 删除所有按钮                                                     |
//+------------------------------------------------------------------+
void DeleteButtons()
{
   for(int i = 0; i < IDX_TOTAL; i++)
   {
      string name = GetBtnName(i);
      ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| 刷新按钮位置(图表大小变化时调用)                                  |
//+------------------------------------------------------------------+
void RefreshButtonPositions()
{
   //--- CORNER_RIGHT_LOWER模式下: 田字形 2×2 排列
   for(int idx = 0; idx < IDX_TOTAL; idx++)
   {
      int col    = idx % 2;
      int row    = idx / 2;
      int btnX   = InpMarginRight + col * (InpBtnWidth + InpBtnGap);
      int btnY   = InpMarginBottom + row * (InpBtnHeight + InpBtnGap);
      string name = GetBtnName(idx);

      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, btnX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, btnY);
   }
}

//+------------------------------------------------------------------+
//| 刷新按钮文字和状态                                               |
//+------------------------------------------------------------------+
void RefreshButtonLabels()
{
   double totalVol = GetTotalVolume();
   bool hasPos = (totalVol > 0);

   //--- 更新全平仓按钮(显示总手数)
   string closeAllLabel = g_btnLabels[IDX_CLOSEALL] + " " + DoubleToString(totalVol, 2);
   ObjectSetString(0, GetBtnName(IDX_CLOSEALL), OBJPROP_TEXT, closeAllLabel);
   SetBtnState(GetBtnName(IDX_CLOSEALL), IDX_CLOSEALL, hasPos);

   //--- 更新其他按钮
   for(int i = 1; i < IDX_TOTAL; i++)
   {
      SetBtnState(GetBtnName(i), i, hasPos);
   }
}

//+------------------------------------------------------------------+
//| 设置按钮状态(启用/禁用)                                          |
//+------------------------------------------------------------------+
void SetBtnState(string name, int idx, bool hasPos)
{
   if(hasPos)
   {
      //--- 有持仓: 正常颜色,可点击
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, g_btnColors[idx]);
      ObjectSetInteger(0, name, OBJPROP_STATE, false);
   }
   else
   {
      //--- 无持仓: 灰色,不可点击
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, InpDisableColor);
      ObjectSetInteger(0, name, OBJPROP_STATE, true);  // 按下状态视觉上像禁用
   }
}

//+------------------------------------------------------------------+
//| 定时器处理(每秒刷新)                                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   RefreshButtonLabels();
}

//+------------------------------------------------------------------+
//| 图表事件处理                                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   //--- 图表大小改变 → 重新定位按钮
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      RefreshButtonPositions();
      return;
   }

   //--- 对象点击事件
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      //--- 检查点击的是否是我们的按钮
      int btnIdx = -1;
      for(int i = 0; i < IDX_TOTAL; i++)
      {
         if(sparam == GetBtnName(i))
         {
            btnIdx = i;
            break;
         }
      }

      if(btnIdx < 0)
         return;

      //--- 取消按钮的按下状态(视觉反馈后恢复)
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

      //--- 检查是否有持仓
      double totalVol = GetTotalVolume();
      if(totalVol <= 0)
      {
         Print("⚠️ 当前品种[", _Symbol, "] 无持仓");
         return;
      }

      //--- 执行平仓
      ExecuteClose(btnIdx);

      //--- 刷新按钮状态
      RefreshButtonLabels();
   }
}

//+------------------------------------------------------------------+
//| 执行平仓                                                         |
//+------------------------------------------------------------------+
void ExecuteClose(int btnIdx)
{
   double totalVol = GetTotalVolume();
   if(totalVol <= 0)
      return;

   double targetVol = 0;

   switch(btnIdx)
   {
      case IDX_CLOSEALL:
         targetVol = totalVol;  // 全平
         break;
      case IDX_HALF:
         targetVol = totalVol * 0.5;  // ½
         break;
      case IDX_THIRD:
         targetVol = totalVol / 3.0;  // ⅓
         break;
      case IDX_QUARTER:
         targetVol = totalVol * 0.25; // ¼
         break;
   }

   //--- 向下取整到合法步长(先 NormalizeDouble 修复浮点精度)
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      step = 0.01;

   targetVol = MathFloor(NormalizeDouble(targetVol / step, 8)) * step;

   //--- 最小手数检查
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVol <= 0)
      minVol = 0.01;

   if(targetVol < minVol)
   {
      Print("⚠️ 计算平仓手数(", DoubleToString(targetVol, 2),
            ") 小于最小手数(", DoubleToString(minVol, 2), "),不执行");
      return;
   }

   //--- 限制不超过总手数
   if(targetVol > totalVol)
      targetVol = totalVol;

   //--- 开始平仓
   string actionStr = (btnIdx == IDX_CLOSEALL) ? "全平仓" :
                       (btnIdx == IDX_HALF)     ? "½平仓" :
                       (btnIdx == IDX_THIRD)    ? "⅓平仓" :
                                                  "¼平仓";

   Print("🔧 执行 ", actionStr, " 目标手数: ", DoubleToString(targetVol, 2),
         " / 总手数: ", DoubleToString(totalVol, 2));

   //--- 收集当前品种所有持仓(按手数从大到小排序,先平大单减少误差)
   PosInfo positions[];
   int posCount = CollectPositions(positions);

   if(posCount == 0)
   {
      Print("⚠️ 未找到持仓");
      return;
   }

   //--- 冒泡排序: 从大到小
   for(int i = 0; i < posCount - 1; i++)
   {
      for(int j = 0; j < posCount - 1 - i; j++)
      {
         if(positions[j].volume < positions[j + 1].volume)
         {
            PosInfo tmp = positions[j];
            positions[j] = positions[j + 1];
            positions[j + 1] = tmp;
         }
      }
   }

   //--- 遍历持仓,按比例平仓
   double remaining = targetVol;
   int   closeCount = 0;
   int   failCount  = 0;
   double closedVol = 0;

   for(int i = 0; i < posCount && remaining > 0; i++)
   {
      ulong ticket   = positions[i].ticket;
      double posVol  = positions[i].volume;

      //--- 计算该单应平手数(先 NormalizeDouble 修复浮点精度)
      double closeVol = posVol / totalVol * targetVol;
      closeVol = MathFloor(NormalizeDouble(closeVol / step, 8)) * step;

      //--- 边界修正
      if(closeVol <= 0)
         closeVol = MathMin(remaining, posVol);
      if(closeVol > remaining)
         closeVol = remaining;
      if(closeVol > posVol)
         closeVol = posVol;
      if(closeVol < minVol && remaining >= minVol)
         closeVol = minVol;

      if(closeVol <= 0)
         continue;

      //--- 确认弹窗
      if(InpShowConfirm)
      {
         string msg = StringFormat("确认 %s?\n品种: %s\n手数: %.2f", actionStr, _Symbol, closeVol);
         int ret = MessageBox(msg, "交易确认", MB_YESNO | MB_ICONQUESTION);
         if(ret != IDYES)
         {
            Print("❌ 用户取消平仓");
            return;
         }
      }

      //--- 执行平仓
      bool result = false;

      if(closeVol >= posVol - step / 2)
      {
         // 接近全平 → 全部平掉
         result = m_trade.PositionClose(ticket);
      }
      else
      {
         // 部分平仓
         result = m_trade.PositionClosePartial(ticket, closeVol, (ulong)InpDeviation);
      }

      if(result)
      {
         closeCount++;
         closedVol += closeVol;
         remaining -= closeVol;
         Print("✅ 平仓成功 Ticket=", ticket, " 手数=", DoubleToString(closeVol, 2));
      }
      else
      {
         failCount++;
         Print("❌ 平仓失败 Ticket=", ticket, " 手数=", DoubleToString(closeVol, 2),
               " 错误: ", m_trade.ResultRetcodeDescription());

         // 尝试全平该单(若部分平仓失败)
         if(closeVol < posVol)
         {
            if(m_trade.PositionClose(ticket))
            {
               closeCount++;
               closedVol += posVol;
               remaining -= posVol;
               Print("✅ 全平成功(部分平回退) Ticket=", ticket);
            }
         }
      }
   }

   //--- 如果有剩余手数(因取整误差),尝试补平
   if(remaining >= minVol)
   {
      for(int i = 0; i < posCount && remaining >= minVol; i++)
      {
         if(!PositionSelectByTicket(positions[i].ticket))
            continue;

         double curVol = PositionGetDouble(POSITION_VOLUME);
         if(curVol <= 0)
            continue;

         double extraVol = MathMin(remaining, curVol);
         extraVol = MathFloor(NormalizeDouble(extraVol / step, 8)) * step;

         if(extraVol >= minVol)
         {
            if(m_trade.PositionClosePartial(positions[i].ticket, extraVol, (ulong)InpDeviation))
            {
               closeCount++;
               closedVol += extraVol;
               remaining -= extraVol;
               Print("✅ 补平成功 Ticket=", positions[i].ticket,
                     " 手数=", DoubleToString(extraVol, 2));
            }
         }
      }
   }

   //--- 打印结果
   Print("┌─────────────────────────────────────────┐");
   Print("│ ", actionStr, " 完成");
   Print("│ 目标手数: ", DoubleToString(targetVol, 2));
   Print("│ 实际平仓: ", DoubleToString(closedVol, 2));
   Print("│ 成功: ", closeCount, " 失败: ", failCount);
   Print("└─────────────────────────────────────────┘");
}

//+------------------------------------------------------------------+
//| 收集当前品种所有持仓                                             |
//+------------------------------------------------------------------+
int CollectPositions(PosInfo &positions[])
{
   ArrayResize(positions, 0);
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         count++;
         ArrayResize(positions, count);
         positions[count - 1].ticket = ticket;
         positions[count - 1].volume = PositionGetDouble(POSITION_VOLUME);
      }
   }

   return count;
}

//+------------------------------------------------------------------+
//| 获取当前品种总持仓手数                                           |
//+------------------------------------------------------------------+
double GetTotalVolume()
{
   double total = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         total += PositionGetDouble(POSITION_VOLUME);
      }
   }

   return total;
}

//+------------------------------------------------------------------+
//| 获取按钮名称                                                     |
//+------------------------------------------------------------------+
string GetBtnName(int idx)
{
   switch(idx)
   {
      case IDX_CLOSEALL: return BTN_CLOSEALL;
      case IDX_HALF:     return BTN_HALF;
      case IDX_THIRD:    return BTN_THIRD;
      case IDX_QUARTER:  return BTN_QUARTER;
      default:           return "";
   }
}
//+------------------------------------------------------------------+
