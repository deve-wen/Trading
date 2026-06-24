//+------------------------------------------------------------------+
//|                                                SR_AutoLevels.mq5 |
//|                                          Senior Developer        |
//|                                                                  |
//|  自动支撑压力划线指标 v2.0.1                                       |
//|                                                                  |
//|  【通达信转MT5 核心逻辑】                                         |
//|    HD:=FILTER(BACKSET(FILTER(REF(H,10)=HHV(H,21),10),11),10);    |
//|    LD:=FILTER(BACKSET(FILTER(REF(L,10)=LLV(L,21),10),11),10);    |
//|    支撑:=REF(LOW,BARSLAST(LD));                                   |
//|    压力:=REF(HIGH,BARSLAST(HD));                                  |
//|                                                                  |
//|  v2.0.1 改进:                                                     |
//|    - 检测逻辑与v1完全一致(6缓冲区+BACKSET+逐KREF)                |
//|    - 全部检测到的级别收集到数组,而非仅保留最新                    |
//|    - 价格上方3条压力线 + 下方3条支撑线,仅横向水平线              |
//+------------------------------------------------------------------+
#property copyright "Senior Developer"
#property version   "2.01"
#property description "自动支撑压力划线指标 v2.01 - 多级别显示"
#property description "通达信风格: FILTER+BACKSET+HHV/LLV 峰值谷值检测"
#property description "检测逻辑与v1完全相同 | 上方3条压力+下方3条支撑 | 仅横向线"
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   0

//+------------------------------------------------------------------+
//| 输入参数                                                         |
//+------------------------------------------------------------------+
input group   "=== ★ 核心参数 ==="
input int     InpLookback       = 10;                 // 峰值检测周期(N): H[j]=HHV(H,2N+1)
input int     InpMinGap         = 10;                 // 最小间隔K线(FILTER)

input group   "=== ★ 显示参数 ==="
input int     InpMaxLevels      = 3;                  // 每侧显示线数
input color   InpSupColor       = clrGreen;           // 支撑线颜色
input color   InpResColor       = clrRed;             // 压力线颜色
input bool    InpShowLabels     = true;               // 显示价格标签
input int     InpFontSize       = 10;                 // 标签字号

//+------------------------------------------------------------------+
//| 缓冲区声明 (与v1完全一致)                                        |
//+------------------------------------------------------------------+
double         supBuffer[];      // 支撑线(INDICATOR_DATA,保留给v1兼容)
double         resBuffer[];      // 压力线(INDICATOR_DATA)
double         hdRaw[];          // [内部] 原始峰值信号(FILTER第一层)
double         ldRaw[];          // [内部] 原始谷值信号
double         hdFinal[];        // [内部] BACKSET后峰值信号
double         ldFinal[];        // [内部] BACKSET后谷值信号

//+------------------------------------------------------------------+
//| 级别结构                                                         |
//+------------------------------------------------------------------+
struct SLevel
{
   double   price;     // 支撑/压力价格
   datetime time;      // 产生K线时间
   int      bar;       // 产生K线索引
};

SLevel         g_resLevels[];      // 所有检测到的压力位(峰值High)
SLevel         g_supLevels[];      // 所有检测到的支撑位(谷值Low)
string         g_prefix = "SRA_";
bool           g_initDone = false;

//+------------------------------------------------------------------+
//| 指标初始化                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 设置缓冲区 (与v1完全一致)
   SetIndexBuffer(0, supBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(1, resBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(2, hdRaw, INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, ldRaw, INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, hdFinal, INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, ldFinal, INDICATOR_CALCULATIONS);

   IndicatorSetString(INDICATOR_SHORTNAME,
      "SRA_v2(" + (string)InpLookback + "," + (string)InpMinGap + ")");

   g_initDone = false;
   ArrayFree(g_resLevels);
   ArrayFree(g_supLevels);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 反初始化                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteAllObjects();
   ArrayFree(g_resLevels);
   ArrayFree(g_supLevels);
}

//+------------------------------------------------------------------+
//| 指标计算主函数                                                    |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   int minBars = 2 * InpLookback + InpMinGap + 2;
   if(rates_total < minBars)
      return(0);

   //=================================================================
   // 第一步: 初始化缓冲区 + 级别数组 (与v1完全一致的初始化)
   //=================================================================
   if(prev_calculated == 0 || !g_initDone)
   {
      ArrayInitialize(supBuffer, 0);
      ArrayInitialize(resBuffer, 0);
      ArrayInitialize(hdRaw, 0);
      ArrayInitialize(ldRaw, 0);
      ArrayInitialize(hdFinal, 0);
      ArrayInitialize(ldFinal, 0);

      ArrayResize(g_resLevels, 0);
      ArrayResize(g_supLevels, 0);
      g_initDone = true;
   }

   //--- 计算起始位置 (与v1完全一致)
   int start = prev_calculated > 0 ? prev_calculated - 2 : InpLookback + 1;
   if(start < InpLookback + 1)
      start = InpLookback + 1;
   if(start >= rates_total)
      start = rates_total - 1;

   int window = 2 * InpLookback + 1;

   //=================================================================
   // 第二步: 峰值谷值检测 (与v1完全一致: hdRaw/ldRaw + BACKSET)
   //=================================================================
   for(int i = start; i < rates_total; i++)
   {
      //--- 重置当前周期信号
      hdRaw[i] = 0;
      ldRaw[i] = 0;

      //--- 被检查的K线: bar[i - InpLookback]
      int checkBar = i - InpLookback;
      if(checkBar < 0 || i + InpLookback >= rates_total)
         continue;

      //=============================================================
      // 峰值检测: H[checkBar] 在 [checkBar-N, checkBar+N] 中最高
      //=============================================================
      double hPeak = high[checkBar];
      bool   isPeak = true;

      for(int j = 0; j < window; j++)
      {
         int idx = checkBar - InpLookback + j;
         if(idx < 0 || idx >= rates_total)
            continue;
         if(idx == checkBar)
            continue;
         if(high[idx] > hPeak)
         {
            isPeak = false;
            break;
         }
      }

      //--- FILTER: 与前一个峰值间隔 >= InpMinGap
      if(isPeak)
      {
         bool canSignal = true;
         for(int f = 1; f <= InpMinGap; f++)
         {
            int fi = i - f;
            if(fi >= 0 && hdRaw[fi] > 0)
            {
               canSignal = false;
               break;
            }
         }

         if(canSignal)
            hdRaw[i] = 1;
      }

      //=============================================================
      // 谷值检测: L[checkBar] 在 [checkBar-N, checkBar+N] 中最低
      //=============================================================
      double lTrough = low[checkBar];
      bool   isTrough = true;

      for(int j = 0; j < window; j++)
      {
         int idx = checkBar - InpLookback + j;
         if(idx < 0 || idx >= rates_total)
            continue;
         if(idx == checkBar)
            continue;
         if(low[idx] < lTrough)
         {
            isTrough = false;
            break;
         }
      }

      if(isTrough)
      {
         bool canSignal = true;
         for(int f = 1; f <= InpMinGap; f++)
         {
            int fi = i - f;
            if(fi >= 0 && ldRaw[fi] > 0)
            {
               canSignal = false;
               break;
            }
         }

         if(canSignal)
            ldRaw[i] = 1;
      }

      //=============================================================
      // BACKSET: 将信号向后延伸 InpMinGap+1 个周期 (与v1完全一致)
      //=============================================================
      if(hdRaw[i] > 0)
      {
         int endPos = i + InpMinGap + 1;
         if(endPos >= rates_total)
            endPos = rates_total - 1;
         for(int b = i; b <= endPos; b++)
            hdFinal[b] = 1;
      }

      if(ldRaw[i] > 0)
      {
         int endPos = i + InpMinGap + 1;
         if(endPos >= rates_total)
            endPos = rates_total - 1;
         for(int b = i; b <= endPos; b++)
            ldFinal[b] = 1;
      }
   }

   //=================================================================
   // 第三步: 扫描全量K线,提取支撑压力级别 (与v1逻辑一致)
   //   v1: 仅保留最新级别 → supBuffer[i]=currSupport,resBuffer[i]=currRes
   //   v2: 收集ALL级别 → 存入g_supLevels/g_resLevels(去重)
   //=================================================================
   for(int i = 0; i < rates_total; i++)
   {
      //--- 支撑: 检查 ldRaw 信号
      if(ldRaw[i] > 0)
      {
         int actualBar = i - InpLookback;
         if(actualBar >= 0 && actualBar < rates_total)
         {
            double price = low[actualBar];
            supBuffer[i] = price;

            // 去重加入支撑级别列表
            bool exists = false;
            int cnt = ArraySize(g_supLevels);
            for(int k = 0; k < cnt; k++)
            {
               if(MathAbs(g_supLevels[k].price - price) < 0.001)
               { exists = true; break; }
            }
            if(!exists)
            {
               ArrayResize(g_supLevels, cnt + 1);
               g_supLevels[cnt].price = price;
               g_supLevels[cnt].time  = time[actualBar];
               g_supLevels[cnt].bar   = actualBar;
            }
         }
      }

      //--- 压力: 检查 hdRaw 信号
      if(hdRaw[i] > 0)
      {
         int actualBar = i - InpLookback;
         if(actualBar >= 0 && actualBar < rates_total)
         {
            double price = high[actualBar];
            resBuffer[i] = price;

            // 去重加入压力级别列表
            bool exists = false;
            int cnt = ArraySize(g_resLevels);
            for(int k = 0; k < cnt; k++)
            {
               if(MathAbs(g_resLevels[k].price - price) < 0.001)
               { exists = true; break; }
            }
            if(!exists)
            {
               ArrayResize(g_resLevels, cnt + 1);
               g_resLevels[cnt].price = price;
               g_resLevels[cnt].time  = time[actualBar];
               g_resLevels[cnt].bar   = actualBar;
            }
         }
      }
   }

   //=================================================================
   // 第四步: 绘制多级别支撑压力线 (仅横向,无竖线)
   //=================================================================
   double currentPrice = close[rates_total - 1];
   DrawLevels(time, rates_total, currentPrice);

   return(rates_total);
}

//+------------------------------------------------------------------+
//| 画支撑压力线 (纯横向,无竖线)                                      |
//+------------------------------------------------------------------+
void DrawLevels(const datetime &time[], int rates_total, double currentPrice)
{
   DeleteAllObjects();

   if(rates_total < 2)
      return;

   datetime lastTime = time[rates_total - 1];
   int      digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //=============================================================
   // 压力位: 筛选高于现价的,按时间倒序(最近优先)取 InpMaxLevels 条
   //=============================================================
   int resTotal = ArraySize(g_resLevels);
   if(resTotal > 0)
   {
      double pricesAbove[];
      int    barsAbove[];
      ArrayResize(pricesAbove, 0);
      ArrayResize(barsAbove, 0);

      for(int i = 0; i < resTotal; i++)
      {
         if(g_resLevels[i].price > currentPrice)
         {
            int idx = ArraySize(pricesAbove);
            ArrayResize(pricesAbove, idx + 1);
            ArrayResize(barsAbove, idx + 1);
            pricesAbove[idx] = g_resLevels[i].price;
            barsAbove[idx]   = g_resLevels[i].bar;
         }
      }

      int count = ArraySize(pricesAbove);
      if(count > 0)
      {
         //--- 按 bar 索引降序排列 (最近K线优先)
         for(int a = 0; a < count - 1; a++)
            for(int b = 0; b < count - 1 - a; b++)
               if(barsAbove[b] < barsAbove[b + 1])
               {
                  double tp = pricesAbove[b];
                  pricesAbove[b] = pricesAbove[b + 1];
                  pricesAbove[b + 1] = tp;
                  int tb = barsAbove[b];
                  barsAbove[b] = barsAbove[b + 1];
                  barsAbove[b + 1] = tb;
               }

         int drawCount = (count < InpMaxLevels) ? count : InpMaxLevels;
         for(int i = 0; i < drawCount; i++)
         {
            double price = pricesAbove[i];
            int    bar   = barsAbove[i];
            if(bar < 0 || bar >= rates_total)
               bar = rates_total - 1;

            // 横向实线: 信号K线 → 最新K线
            string mn = g_prefix + "R_M_" + (string)i;
            ObjectCreate(0, mn, OBJ_TREND, 0,
               time[bar], price, lastTime, price);
            ObjectSetInteger(0, mn, OBJPROP_COLOR, InpResColor);
            ObjectSetInteger(0, mn, OBJPROP_STYLE, STYLE_SOLID);
            ObjectSetInteger(0, mn, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, mn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, mn, OBJPROP_HIDDEN, true);

            // 虚线射线: 最新K线向右延伸
            string rn = g_prefix + "R_R_" + (string)i;
            ObjectCreate(0, rn, OBJ_TREND, 0,
               lastTime, price, lastTime, price);
            ObjectSetInteger(0, rn, OBJPROP_RAY_RIGHT, true);
            ObjectSetInteger(0, rn, OBJPROP_COLOR, InpResColor);
            ObjectSetInteger(0, rn, OBJPROP_STYLE, STYLE_DASH);
            ObjectSetInteger(0, rn, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, rn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, rn, OBJPROP_HIDDEN, true);

            // 标签
            if(InpShowLabels)
            {
               string ln = g_prefix + "R_L_" + (string)i;
               ObjectCreate(0, ln, OBJ_TEXT, 0, lastTime, price);
               ObjectSetString(0, ln, OBJPROP_TEXT,
                  DoubleToString(price, digits));
               ObjectSetInteger(0, ln, OBJPROP_COLOR, InpResColor);
               ObjectSetInteger(0, ln, OBJPROP_FONTSIZE, InpFontSize);
               ObjectSetInteger(0, ln, OBJPROP_ANCHOR, ANCHOR_LEFT);
               ObjectSetInteger(0, ln, OBJPROP_HIDDEN, true);
            }
         }
      }
   }

   //=============================================================
   // 支撑位: 筛选低于现价的,按时间倒序(最近优先)取 InpMaxLevels 条
   //=============================================================
   int supTotal = ArraySize(g_supLevels);
   if(supTotal > 0)
   {
      double pricesBelow[];
      int    barsBelow[];
      ArrayResize(pricesBelow, 0);
      ArrayResize(barsBelow, 0);

      for(int i = 0; i < supTotal; i++)
      {
         if(g_supLevels[i].price < currentPrice)
         {
            int idx = ArraySize(pricesBelow);
            ArrayResize(pricesBelow, idx + 1);
            ArrayResize(barsBelow, idx + 1);
            pricesBelow[idx] = g_supLevels[i].price;
            barsBelow[idx]   = g_supLevels[i].bar;
         }
      }

      int count = ArraySize(pricesBelow);
      if(count > 0)
      {
         //--- 按 bar 索引降序排列 (最近K线优先)
         for(int a = 0; a < count - 1; a++)
            for(int b = 0; b < count - 1 - a; b++)
               if(barsBelow[b] < barsBelow[b + 1])
               {
                  double tp = pricesBelow[b];
                  pricesBelow[b] = pricesBelow[b + 1];
                  pricesBelow[b + 1] = tp;
                  int tb = barsBelow[b];
                  barsBelow[b] = barsBelow[b + 1];
                  barsBelow[b + 1] = tb;
               }

         int drawCount = (count < InpMaxLevels) ? count : InpMaxLevels;
         for(int i = 0; i < drawCount; i++)
         {
            double price = pricesBelow[i];
            int    bar   = barsBelow[i];
            if(bar < 0 || bar >= rates_total)
               bar = rates_total - 1;

            // 横向实线: 信号K线 → 最新K线
            string mn = g_prefix + "S_M_" + (string)i;
            ObjectCreate(0, mn, OBJ_TREND, 0,
               time[bar], price, lastTime, price);
            ObjectSetInteger(0, mn, OBJPROP_COLOR, InpSupColor);
            ObjectSetInteger(0, mn, OBJPROP_STYLE, STYLE_SOLID);
            ObjectSetInteger(0, mn, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, mn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, mn, OBJPROP_HIDDEN, true);

            // 虚线射线: 最新K线向右延伸
            string rn = g_prefix + "S_R_" + (string)i;
            ObjectCreate(0, rn, OBJ_TREND, 0,
               lastTime, price, lastTime, price);
            ObjectSetInteger(0, rn, OBJPROP_RAY_RIGHT, true);
            ObjectSetInteger(0, rn, OBJPROP_COLOR, InpSupColor);
            ObjectSetInteger(0, rn, OBJPROP_STYLE, STYLE_DASH);
            ObjectSetInteger(0, rn, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, rn, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, rn, OBJPROP_HIDDEN, true);

            // 标签
            if(InpShowLabels)
            {
               string ln = g_prefix + "S_L_" + (string)i;
               ObjectCreate(0, ln, OBJ_TEXT, 0, lastTime, price);
               ObjectSetString(0, ln, OBJPROP_TEXT,
                  DoubleToString(price, digits));
               ObjectSetInteger(0, ln, OBJPROP_COLOR, InpSupColor);
               ObjectSetInteger(0, ln, OBJPROP_FONTSIZE, InpFontSize);
               ObjectSetInteger(0, ln, OBJPROP_ANCHOR, ANCHOR_LEFT);
               ObjectSetInteger(0, ln, OBJPROP_HIDDEN, true);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 删除所有本指标创建的对象                                          |
//+------------------------------------------------------------------+
void DeleteAllObjects()
{
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, g_prefix) == 0)
         ObjectDelete(0, name);
   }
}
//+------------------------------------------------------------------+
