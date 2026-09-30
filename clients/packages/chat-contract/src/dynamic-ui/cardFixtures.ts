import type {
  ChecklistData,
  ComparisonData,
  CompositionData,
  FeedData,
  ForecastData,
  MetricData,
  OptionsData,
  PlaceData,
  ScheduleData,
  TimerData,
  TrendData,
} from "./cardTypes";

/** Representative facts an Agent would pass to `comma.card`. Used by stories and tests. */

export const forecastFixture: ForecastData = {
  title: "杭州 · 未来 7 天",
  location: "杭州",
  source: "中国天气网",
  updatedAt: "17:05 更新",
  current: {
    temperature: 26,
    condition: "partly-cloudy",
    label: "多云",
    feelsLike: 28,
    humidity: 72,
    wind: "东北风 3 级",
  },
  highlight: "周五有小雨，最高温降到 26°",
  days: [
    {
      label: "今天",
      condition: "partly-cloudy",
      conditionLabel: "多云",
      high: 30,
      low: 21,
      precipitation: 10,
    },
    {
      label: "周四",
      condition: "clear",
      conditionLabel: "晴",
      high: 31,
      low: 22,
      precipitation: 0,
    },
    {
      label: "周五",
      condition: "rain",
      conditionLabel: "小雨",
      high: 26,
      low: 20,
      precipitation: 70,
    },
    {
      label: "周六",
      condition: "cloudy",
      conditionLabel: "阴",
      high: 27,
      low: 21,
      precipitation: 20,
    },
    {
      label: "周日",
      condition: "partly-cloudy",
      conditionLabel: "多云",
      high: 29,
      low: 22,
      precipitation: 10,
    },
    {
      label: "周一",
      condition: "clear",
      conditionLabel: "晴",
      high: 31,
      low: 23,
      precipitation: 0,
    },
    {
      label: "周二",
      condition: "rain",
      conditionLabel: "阵雨",
      high: 28,
      low: 22,
      precipitation: 60,
    },
  ],
  actions: [{ label: "周末出行建议", prompt: "根据杭州这周末的天气，给我出行建议" }],
};

export const trainOptionsFixture: OptionsData = {
  title: "杭州东 → 上海虹桥 · 今晚",
  meta: "5 班",
  source: "12306",
  updatedAt: "17:02 查询",
  filters: [
    { key: "all", label: "全部" },
    { key: "available", label: "有票" },
    { key: "fast", label: "1 小时内" },
  ],
  items: [
    {
      id: "G7502",
      primary: "19:10",
      secondary: "20:02",
      span: "52 分",
      meta: "G7502 · 二等座",
      price: "¥73",
      status: { label: "有票", tone: "success" },
      filterKeys: ["all", "available", "fast"],
    },
    {
      id: "G1662",
      primary: "20:05",
      secondary: "20:50",
      span: "45 分",
      meta: "G1662 · 二等座",
      price: "¥78",
      status: { label: "有票", tone: "success" },
      tags: ["最快"],
      recommended: true,
      reason: "45 分钟到，比其他车次快 7 分钟以上，20:50 到虹桥还能赶上地铁。",
      filterKeys: ["all", "available", "fast"],
    },
    {
      id: "G7314",
      primary: "19:35",
      secondary: "20:24",
      span: "49 分",
      meta: "G7314 · 二等座",
      price: "¥73",
      status: { label: "余 3 张", tone: "warning" },
      filterKeys: ["all", "available", "fast"],
    },
    {
      id: "D3136",
      primary: "20:30",
      secondary: "21:48",
      span: "1 时 18 分",
      meta: "D3136 · 二等座",
      price: "¥49",
      status: { label: "有票", tone: "success" },
      tags: ["最便宜"],
      filterKeys: ["all", "available"],
    },
    {
      id: "G7348",
      primary: "21:15",
      secondary: "22:05",
      span: "50 分",
      meta: "G7348 · 二等座",
      price: "¥73",
      status: { label: "候补", tone: "neutral" },
      filterKeys: ["all", "fast"],
    },
  ],
  actions: [{ label: "查看明早车次", prompt: "查一下明天早上杭州东到上海虹桥的车次" }],
};

export const hotelOptionsFixture: OptionsData = {
  title: "静安寺附近 · 今晚 1 晚 · 2 人",
  meta: "3 家",
  source: "携程",
  updatedAt: "16:58 查询",
  items: [
    {
      id: "shangri-la",
      primary: "静安香格里拉大酒店",
      meta: "4.7 分 · 1,203 条评价 · 距地铁 150 m",
      price: "¥1,520",
      priceNote: "/晚",
      tags: ["含早"],
      recommended: true,
      reason: "比瑞吉便宜 ¥360，评分只低 0.1，含双早，步行 2 分钟到静安寺站。",
    },
    {
      id: "st-regis",
      primary: "上海静安瑞吉酒店",
      meta: "4.8 分 · 986 条评价 · 距地铁 600 m",
      price: "¥1,880",
      priceNote: "/晚",
    },
    {
      id: "ji-hotel",
      primary: "全季酒店（南京西路店）",
      meta: "4.6 分 · 3,402 条评价 · 距地铁 300 m",
      price: "¥489",
      priceNote: "/晚",
    },
  ],
};

export const metricFixture: MetricData = {
  title: "本周活跃用户",
  source: "Amplitude",
  updatedAt: "9/16–9/22",
  metrics: [
    {
      label: "周活跃用户",
      value: "12,480",
      delta: { value: "12.4%", direction: "up", good: true },
      caption: "较上周",
      series: [9820, 10150, 10040, 10890, 11320, 11910, 12480],
    },
  ],
};

export const metricGridFixture: MetricData = {
  title: "9 月经营概览",
  source: "Stripe",
  updatedAt: "截至 9/22",
  metrics: [
    {
      label: "收入",
      value: "¥86.2",
      unit: "万",
      delta: { value: "8.1%", direction: "up", good: true },
    },
    {
      label: "订单",
      value: "3,214",
      delta: { value: "5.6%", direction: "up", good: true },
    },
    {
      label: "转化率",
      value: "3.8",
      unit: "%",
      delta: { value: "0.4 pp", direction: "down", good: false },
    },
    {
      label: "退款率",
      value: "1.2",
      unit: "%",
      delta: { value: "0.3 pp", direction: "down", good: true },
    },
  ],
};

export const goalFixture: MetricData = {
  title: "Q3 销售目标",
  source: "Salesforce",
  updatedAt: "9/22 更新",
  metrics: [],
  goal: {
    current: 746,
    target: 1000,
    valueLabel: "¥746 万",
    targetLabel: "目标 ¥1,000 万",
    note: "还差 ¥254 万，剩 8 天，日均需 ¥31.8 万",
  },
};

export const trendFixture: TrendData = {
  title: "比特币 BTC / USD",
  brand: "bitcoin",
  source: "CoinGecko",
  updatedAt: "17:04",
  value: "$63,240",
  delta: { value: "2.8% 今日", direction: "up", good: true },
  ranges: [
    {
      key: "day",
      label: "1 天",
      points: [
        61520, 61380, 61640, 61910, 61750, 62080, 62410, 62230, 62690, 62940, 62810,
        63240,
      ],
      axis: ["06:00", "10:00", "14:00", "17:00"],
    },
    {
      key: "week",
      label: "1 周",
      points: [58910, 59620, 60480, 59870, 61230, 62150, 63240],
      axis: ["周四", "周六", "周一", "今天"],
    },
    {
      key: "month",
      label: "1 月",
      points: [
        54210, 55120, 56480, 55930, 57240, 58810, 58120, 59640, 60780, 61920, 62410,
        63240,
      ],
      axis: ["8/24", "9/3", "9/13", "今天"],
    },
    {
      key: "year",
      label: "1 年",
      points: [
        26400, 29800, 34200, 42100, 51800, 61200, 66400, 62800, 58300, 60400, 57900,
        63240,
      ],
      axis: ["2025/10", "2026/2", "2026/6", "今天"],
    },
  ],
};

export const barTrendFixture: TrendData = {
  title: "近 14 天 API 调用量",
  source: "Comma 控制台",
  updatedAt: "今天 17:00",
  value: "1.38 万",
  delta: { value: "21% 较日均", direction: "up", good: true },
  bars: {
    labels: [
      "9/10",
      "9/11",
      "9/12",
      "9/13",
      "9/14",
      "9/15",
      "9/16",
      "9/17",
      "9/18",
      "9/19",
      "9/20",
      "9/21",
      "9/22",
      "9/23",
    ],
    values: [
      9.2, 10.1, 9.8, 11.4, 7.2, 6.8, 10.9, 11.8, 12.1, 11.2, 7.9, 7.4, 12.6, 13.8,
    ],
    valueLabels: ["", "", "", "", "", "", "", "", "", "", "", "", "", "1.38 万"],
    averageLabel: "日均 1.02 万",
  },
};

export const watchlistFixture: TrendData = {
  title: "自选股",
  source: "Yahoo Finance",
  updatedAt: "收盘价 9/22",
  series: [
    {
      label: "AAPL",
      brand: "apple",
      value: "229.40",
      delta: { value: "1.2%", direction: "up", good: true },
      points: [224, 225.2, 223.8, 226.1, 227.4, 226.9, 229.4],
    },
    {
      label: "NVDA",
      brand: "nvidia",
      value: "118.62",
      delta: { value: "2.3%", direction: "down", good: false },
      points: [124.1, 122.8, 123.4, 121.2, 120.6, 121.4, 118.62],
    },
    {
      label: "TSLA",
      value: "248.10",
      delta: { value: "4.5%", direction: "up", good: true },
      points: [231, 236.4, 234.2, 239.8, 241.1, 237.4, 248.1],
    },
    {
      label: "GOOGL",
      brand: "google",
      value: "251.34",
      delta: { value: "0.4%", direction: "up", good: true },
      points: [248.4, 249.9, 247.6, 250.2, 251.8, 249.5, 251.34],
    },
  ],
};

export const comparisonFixture: ComparisonData = {
  title: "Spotify vs Apple Music · 个人方案",
  source: "两家官网（美区）",
  updatedAt: "9/23",
  subjects: [
    { name: "Spotify", brand: "spotify", caption: "Premium Individual" },
    {
      name: "Apple Music",
      brand: "apple-music",
      caption: "Individual",
      recommended: true,
    },
  ],
  rows: [
    { label: "月费", values: ["$11.99", "$10.99"], best: 1 },
    { label: "免费版", values: ["有，含广告", "无"], best: 0 },
    { label: "无损", values: ["支持", "支持 · 空间音频"], best: 1 },
    { label: "设备", values: ["全平台", "Apple 设备最佳"], best: 0 },
    { label: "学生价", values: ["$5.99", "$5.99"] },
  ],
  verdict: "用 iPhone、在意空间音频选 Apple Music；要免费版或常换设备选 Spotify。",
};

export const planComparisonFixture: ComparisonData = {
  title: "三家运营商 5G 套餐",
  source: "各运营商官网",
  updatedAt: "9 月",
  subjects: [
    { name: "移动 · 畅享 129", caption: "每月 ¥129" },
    { name: "联通 · 冰激凌 99", caption: "每月 ¥99", recommended: true },
    { name: "电信 · 融合 119", caption: "每月 ¥119" },
  ],
  rows: [
    { label: "通用流量", values: ["60 GB", "40 GB", "50 GB"], best: 0 },
    { label: "通话", values: ["500 分钟", "300 分钟", "1000 分钟"], best: 2 },
    { label: "宽带", values: ["—", "300M", "500M"], best: 2 },
    { label: "月费", values: ["¥129", "¥99", "¥119"], best: 1 },
  ],
  verdict: "流量用得多选移动；要宽带和通话选电信；联通最便宜。",
};

export const versusFixture: ComparisonData = {
  title: "Notion vs Linear · 团队项目管理",
  source: "团队 12 人试用两周的评分",
  subjects: [
    { name: "Notion", brand: "notion" },
    { name: "Linear", brand: "linear", recommended: true },
  ],
  rows: [
    { label: "上手速度", values: ["6", "9"], scores: [6, 9] },
    { label: "灵活性", values: ["9", "6"], scores: [9, 6] },
    { label: "迭代规划", values: ["5", "9"], scores: [5, 9] },
    { label: "文档协作", values: ["9", "4"], scores: [9, 4] },
    { label: "价格", values: ["8", "7"], scores: [8, 7] },
  ],
  verdict: "只管需求和迭代选 Linear；文档和知识库也要放一起，选 Notion。",
};

export const agendaFixture: ScheduleData = {
  title: "今天 · 9 月 23 日 周三",
  meta: "5 个日程",
  source: "Google 日历",
  sourceBrand: "google",
  now: "10:35",
  summary: "下一个：11:00 设计评审，还有 25 分钟",
  events: [
    { start: "09:30", end: "10:00", title: "产品站会", detail: "Zoom", state: "done" },
    {
      start: "10:00",
      end: "10:45",
      title: "面试 · 前端工程师",
      detail: "会议室 B · 李想",
      state: "current",
      tone: "warning",
    },
    {
      start: "11:00",
      end: "12:00",
      title: "设计评审：卡片组件",
      detail: "会议室 A · 6 人",
      state: "upcoming",
      tone: "brand",
    },
    {
      start: "14:00",
      end: "14:30",
      title: "1:1 · Kevin",
      detail: "咖啡区",
      state: "upcoming",
      tone: "success",
    },
    {
      start: "16:30",
      end: "17:30",
      title: "季度复盘",
      detail: "大会议室 · 全员",
      state: "upcoming",
      tone: "brand",
    },
  ],
};

export const itineraryFixture: ScheduleData = {
  title: "东京行程 · 第 1 天",
  source: "行程单",
  updatedAt: "9/23 整理",
  events: [
    {
      start: "08:40",
      title: "萧山机场 T4 出发",
      detail: "东航 MU523 · 登机口 C12",
      state: "done",
    },
    {
      start: "12:55",
      title: "抵达成田机场 T2",
      detail: "当地时间 · 飞行 3 时 15 分",
      state: "current",
    },
    {
      start: "14:30",
      title: "Skyliner 到上野",
      detail: "约 41 分钟 · ¥2,580",
      state: "upcoming",
    },
    {
      start: "15:30",
      title: "新宿格拉斯丽酒店入住",
      detail: "订单 #TK20931 · 2 晚",
      state: "upcoming",
    },
    {
      start: "19:00",
      title: "晚餐 · 鸟贵族 新宿东口店",
      detail: "已订 2 人位",
      state: "upcoming",
    },
  ],
};

export const stagesFixture: ScheduleData = {
  title: "订单 #A2931 · AirPods Pro",
  source: "顺丰速运",
  updatedAt: "17:01 更新",
  summary: "预计 9 月 25 日 送达",
  stages: [
    { label: "已下单", detail: "9/20", state: "done" },
    { label: "已发货", detail: "9/21", state: "done" },
    { label: "运输中", detail: "上海转运中心", state: "current" },
    { label: "派送中", state: "upcoming" },
    { label: "已签收", state: "upcoming" },
  ],
};

export const checklistFixture: ChecklistData = {
  title: "v2.3 发布前检查",
  source: "Linear · REL-128",
  sourceBrand: "linear",
  groups: [
    {
      items: [
        { id: "changelog", label: "更新变更日志", done: true },
        {
          id: "regression",
          label: "回归测试全部通过",
          done: true,
          detail: "412 / 412",
        },
        { id: "support", label: "通知客服团队", done: true },
        {
          id: "canary",
          label: "灰度 10%，观察 30 分钟",
          done: false,
          detail: "负责人：王磊",
        },
        { id: "rollout", label: "全量发布", done: false },
        { id: "announce", label: "发布公告与邮件", done: false },
        { id: "review", label: "发布复盘", done: false, detail: "周五 16:00" },
      ],
    },
  ],
};

export const groupedChecklistFixture: ChecklistData = {
  title: "明天出差 · 行前清单",
  groups: [
    {
      label: "证件",
      items: [
        { id: "passport", label: "护照", done: true },
        { id: "id", label: "身份证", done: true },
        { id: "visa", label: "签证页复印件", done: false },
      ],
    },
    {
      label: "电子设备",
      items: [
        { id: "power", label: "充电宝（≤ 20000mAh）", done: true },
        { id: "adapter", label: "日标转换插头", done: false },
        { id: "sim", label: "境外流量卡", done: false },
      ],
    },
    {
      label: "工作",
      items: [
        { id: "slides", label: "路演 PPT 离线版", done: false, detail: "放进 iPad" },
      ],
    },
  ],
};

export const compositionFixture: CompositionData = {
  title: "9 月支出",
  source: "招商银行账单",
  updatedAt: "截至 9/22",
  total: "¥12,860",
  totalLabel: "本月已支出",
  segments: [
    { label: "住房", value: 5200, valueLabel: "¥5,200" },
    { label: "餐饮", value: 2980, valueLabel: "¥2,980" },
    { label: "购物", value: 2160, valueLabel: "¥2,160" },
    { label: "交通", value: 1120, valueLabel: "¥1,120" },
    { label: "其他", value: 1400, valueLabel: "¥1,400" },
  ],
};

export const storageFixture: CompositionData = {
  title: "MacBook 磁盘空间",
  source: "系统设置",
  total: "40 GB",
  totalLabel: "可用 / 512 GB",
  segments: [
    { label: "照片", value: 196, valueLabel: "196 GB" },
    { label: "应用", value: 142, valueLabel: "142 GB" },
    { label: "文稿", value: 88, valueLabel: "88 GB" },
    { label: "系统", value: 46, valueLabel: "46 GB" },
    { label: "可用", value: 40, valueLabel: "40 GB", muted: true },
  ],
};

export const placeFixture: PlaceData = {
  title: "附近的咖啡馆",
  source: "高德地图",
  updatedAt: "17:03",
  places: [
    {
      name: "Blue Bottle 兴业太古汇店",
      category: "咖啡馆",
      rating: 4.6,
      reviews: "2,310 条评价",
      status: { label: "营业中 · 22:00 打烊", tone: "success" },
      address: "静安区石门一路 288 号兴业太古汇 L1",
      distance: "650 m",
      eta: "步行 9 分钟",
      href: "https://www.amap.com/",
    },
    {
      name: "% Arabica 静安寺店",
      category: "咖啡馆",
      rating: 4.5,
      reviews: "1,842 条评价",
      status: { label: "营业中 · 21:00 打烊", tone: "success" },
      distance: "900 m",
      eta: "步行 12 分钟",
      href: "https://www.amap.com/",
    },
    {
      name: "Manner Coffee 南京西路店",
      category: "咖啡馆",
      rating: 4.4,
      reviews: "956 条评价",
      status: { label: "即将打烊 · 18:00", tone: "warning" },
      distance: "1.2 km",
      eta: "步行 16 分钟",
      href: "https://www.amap.com/",
    },
    {
      name: "Seesaw 愚园路店",
      category: "咖啡馆",
      rating: 4.5,
      reviews: "1,120 条评价",
      status: { label: "已打烊", tone: "neutral" },
      distance: "1.6 km",
      eta: "骑行 8 分钟",
      href: "https://www.amap.com/",
    },
  ],
};

export const newsFixture: FeedData = {
  title: "今日 AI 要闻",
  source: "5 个订阅源",
  updatedAt: "17:00 汇总",
  items: [
    {
      source: "Apple Newsroom",
      brand: "apple",
      title: "Apple 在 macOS 27 中开放系统级 Agent 接口，第三方助手可直接操作应用",
      time: "2 小时前",
      href: "https://www.apple.com/newsroom/",
    },
    {
      source: "36氪",
      title: "国内首批通过大模型备案的 Agent 平台公布，覆盖办公与客服场景",
      excerpt: "12 家企业入选，其中 7 家主打办公自动化。",
      time: "3 小时前",
      href: "https://36kr.com/",
    },
    {
      source: "Hacker News",
      title: "Show HN: 用 300 行代码实现的本地语义搜索，支持百万级文档",
      time: "5 小时前",
      href: "https://news.ycombinator.com/",
    },
    {
      source: "GitHub Blog",
      brand: "github",
      title: "Copilot 支持在 Issue 里直接指派 Agent，修完自动开 PR",
      time: "6 小时前",
      href: "https://github.blog/",
    },
  ],
};

export const digestFixture: FeedData = {
  title: "下午好 · 你离开期间",
  updatedAt: "13:00–17:00",
  groups: [
    {
      source: "Gmail",
      brand: "google",
      count: 12,
      summary: "3 封需要回复：法务合同修订、面试安排、报销驳回",
      tone: "warning",
    },
    {
      source: "Slack",
      brand: "slack",
      count: 8,
      summary: "#design 有人 @你 确认卡片组件的暗色方案",
      tone: "brand",
    },
    {
      source: "GitHub",
      brand: "github",
      count: 3,
      summary: "2 个 PR 等你审查，1 个 CI 失败（web-e2e）",
      tone: "error",
    },
    {
      source: "Linear",
      brand: "linear",
      count: 5,
      summary: "REL-128 已进入灰度，另有 4 个任务状态更新",
      tone: "neutral",
    },
  ],
};

export const timerFixture: TimerData = {
  title: "专注计时",
  label: "写季度复盘",
  remainingSeconds: 1104,
  totalSeconds: 1500,
  phase: "focus",
  cycle: { current: 2, total: 4 },
  note: "结束后休息 5 分钟",
};

export const breakTimerFixture: TimerData = {
  title: "休息一下",
  label: "起来走走，喝点水",
  remainingSeconds: 212,
  totalSeconds: 300,
  phase: "break",
  paused: true,
  cycle: { current: 2, total: 4 },
  note: "之后开始第 3 个番茄钟",
};

export const eventCountdownFixture: TimerData = {
  title: "倒数日",
  label: "距 Comma 2.0 发布",
  daysLeft: 12,
  date: "10 月 5 日 周日",
  elapsedRatio: 0.71,
  note: "计划周期 42 天，已过 30 天",
};
