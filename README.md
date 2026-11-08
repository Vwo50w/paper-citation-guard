# paper-citation-guard · 论文引用防伪核验

> **先有页面，才有引用。**
> 大模型写文献综述最爱干的事，就是编几篇看起来很像真的论文。这个工具做的事只有一件：
> **每条参考文献背后必须有一个真实抓取到的页面，链接和元数据全部来自那个页面。**

一个给 DeepSeek Harness（DSH）用的技能，核心是一支可独立运行的 PowerShell 脚本。

```
❌ 梁茂成. 大语言模型对外语教学与研究的挑战与应对[J]. 外语界, 2023(3): 10-16.
   （查无此文，作者、刊名、页码全对得上，唯独文章不存在）

✅ 徐锦芬, 刘文波. 大中小学外语教材思政内容一体化建设研究[J]. 外语界, 2023(3).
   https://www.cnki.com.cn/Article/CJFDTotal-WYJY202303003.htm
   （题名、作者、刊名、年期，全部取自此页面）
```

## 它解决什么

用大模型写论文时，最常见的三种坑：

1. **编造文献** —— 作者真、期刊真、年份合理，文章不存在。
2. **引用不规范** —— 格式凭印象写，卷期页对不上。
3. **查了但说不清查了什么** —— "我查过了"无法验证。

对应三条硬规则：

| 规则 | 做法 |
|---|---|
| 无链接不引用 | 每条后面必须跟论文落地页或 DOI 解析地址 |
| 字段只抄不补 | 页面没给的页码写"未提供"，绝不按常识补齐 |
| 必须报覆盖 | 每次交付注明查了哪些库、哪些库没查（缺 key / 无接口） |

## 数据源：22 个

| 类型 | 源 |
|---|---|
| 综合 | OpenAlex、CrossRef、Semantic Scholar\*、CORE\*、OpenAIRE |
| 学科 | Europe PMC、PubMed\*、arXiv、bioRxiv |
| 开放获取 | DOAJ、DataCite |
| 商业全文 | Scopus\*、ScienceDirect\*、Web of Science\*、Springer\* |
| 中文 | 中国知网（目录枚举）、万方、维普、国家哲社文献中心 |
| 全文定位 | Unpaywall（按 DOI 查有没有免费全文） |

`*` 需要 API key 或机构订阅。

**没有公开检索接口的**（IEEE、JSTOR、万方、维普、哲社中心、bioRxiv）会被明确标注，**不会假装查过**。

## 安装

### 作为 DSH 技能

```powershell
# 用户级（对所有项目生效）
git clone https://github.com/<you>/paper-citation-guard.git "$env:USERPROFILE\.dsh\skills\paper-citation-guard"
```

或者项目级：克隆到 `<你的项目>/.dsh/skills/paper-citation-guard`。

然后自检：

```bash
python3 ~/.dsh/skills/paper-citation-guard/scripts/refcheck.py doctor -InitConfig
```

`doctor` 会逐个探活 22 个源，告诉你哪些能连、哪些缺 key、缺的是哪个字段，并生成 `config.json` 模板。

### 只用脚本

不装 DSH 也能用，脚本是独立的。**首选 Python 3**（只用标准库，macOS/Linux 自带）：

```bash
python3 scripts/refcheck.py search "generative AI feedback L2 writing" -Since 2022
```

Windows 没有 Python 时用 PowerShell 7 版本，参数完全一样：

```powershell
pwsh -File scripts\refcheck.ps1 search "generative AI feedback L2 writing" -Since 2022
```

或者用平台入口，它会自动挑可用的那个：

```bash
./scripts/refcheck.sh  search "..."      # Unix
scripts\refcheck.cmd   search "..."      # Windows
```

## 兼容性

**技能格式**：本仓库用 `SKILL.md` + YAML frontmatter（`name` / `description`），这是 Agent Skills 的通用格式。DSH、Claude Code、Claude.ai 等按同一规范加载技能，把它们放进各自的技能目录即可：

| Agent | 技能目录 |
|---|---|
| DeepSeek Harness | `~/.dsh/skills/` 或 `<项目>/.dsh/skills/` |
| Claude Code | `~/.claude/skills/` 或 `<项目>/.claude/skills/` |
| 其他遵循 Agent Skills 的客户端 | 各自的 `skills/` 目录 |

**运行时**：两套实现，共用 `providers.json` / `config.json` / `cache/`，行为一致。

| 实现 | 依赖 | Windows | macOS | Linux |
|---|---|---|---|---|
| `refcheck.py` | Python 3.8+ 标准库 | ✅ | ✅ 自带 | ✅ 自带 |
| `refcheck.ps1` | PowerShell 7 | ✅ | 需 `brew install --cask powershell` | 需 `snap install powershell --classic` |

推荐 Python：不需要装任何第三方包，也不用额外装运行时。

`scripts\refcheck.cmd` 和 `scripts/refcheck.sh` 是平台入口，会自动挑可用的实现，两个都没有时直接告诉你去装什么，不会静默失败。

## 用法

```bash
# 环境自检（换机器第一件事）
python3 scripts/refcheck.py doctor

# 核验一条（DOI / 链接 / 标题，三选一）
python3 scripts/refcheck.py verify -Doi 10.1016/j.asw.2023.100745
python3 scripts/refcheck.py verify -Query "Using ChatGPT for second language writing"

# 按主题找文献（15 个库并发）
python3 scripts/refcheck.py search "automated writing evaluation feedback" -Since 2022 -Limit 8

# 从页面直接生成规范引用（GB/T 7714-2015 或 APA）
python3 scripts/refcheck.py page -Url https://www.cnki.com.cn/Article/CJFDTotal-WYJY202303003.htm

# 某本刊某几年里按主题找（中文最可靠的路子）
python3 scripts/refcheck.py search "反馈" -In 外语界 -Since 2022

# 某一期的完整目录
python3 scripts/refcheck.py toc -Journal 外语界 -Year 2023 -Issue 3
```

> Windows 用 PowerShell 版时，把 `python3 scripts/refcheck.py` 换成 `pwsh -File scripts\refcheck.ps1`，参数完全一样。

常用开关：`-Since/-Until` 年份过滤、`-Style apa|both` 引用格式、`-Json` 机器可读、`-WithAbstract` 取摘要。

### 输出

```
[1] ✔ VERIFIED  sim=0.94  · OpenAlex
  题名  Using ChatGPT for second language writing: Pitfalls and potentials
  作者  Barrot J S
  来源  Assessing Writing · 2023 · 第 57 卷 · 100745
  链接  https://doi.org/10.1016/j.asw.2023.100745
  引用  Barrot J S. Using ChatGPT for second language writing: Pitfalls and potentials[J].
        Assessing Writing, 2023, 57: 100745. https://doi.org/10.1016/j.asw.2023.100745.

核验：verified=1  未核到=0
覆盖：已查 OpenAlex、CrossRef、Europe PMC；未查 Scopus（缺 key）
```

相似度低于 0.80 一律判 `WEAK`，**不允许拿相近的一篇顶上**。

## 中文文献怎么解决

知网、万方、维普都没有公开检索接口。这个项目用了一个不依赖搜索引擎的办法：

知网的文章地址是**连续编号**的。

```
CJFDTotal-<刊号4位><年4位><期2位><序号3位>.htm
例：CJFDTotal-WYJY202303007.htm
```

于是一期就是一个连续号段，逐号探过去就能把整期目录连作者一起扒出来，结果缓存在 `cache/`。

内置刊号：`WYJY` 外语界、`WYDH` 外语电化教学、`XDWY` 现代外语、`JFJW` 解放军外国语学院学报、`SDJX` 齐鲁师范学院学报、`SJXB` 成都师范学院学报。其他刊物直接传刊号。

**注意**：知网会限流。脚本做了自适应降速、失败重试、半截数据不缓存，但一次扫多年仍然可能中断——按年分批扫，缓存会逐次累积。

## 配置

复制 `config.example.json` 为 `config.json`：

```json
{
  "email": "you@example.com",
  "providers": {
    "semanticscholar": { "apiKey": "" },
    "core": { "apiKey": "" }
  }
}
```

| 库 | 申请地址 | 备注 |
|---|---|---|
| Semantic Scholar | https://www.semanticscholar.org/product/api | 免费，无 key 常被 429 |
| CORE | https://core.ac.uk/services/api | 免费 |
| Springer Nature | https://dev.springernature.com | 免费额度 |
| Scopus / ScienceDirect | https://dev.elsevier.com | 机构订阅 |
| Web of Science | https://developer.clarivate.com | 机构订阅 |
| PubMed | https://www.ncbi.nlm.nih.gov/account/ | 可选，提高频率上限 |

`email` 建议填上：CrossRef 会进 polite pool，Unpaywall 才会返回免费全文地址。

## 设计取舍

- **宁可少一条，不留一条没根据的。** 查不到就说查不到，并列出查过哪些库。
- **失败 ≠ 空。** 被限流会明确警告"共 N 期没抓到，结果不完整"，而不是静默返回 0 条。
- **不缓存半截数据。** 抓一半被打断的结果不写缓存，避免 30 天内一直少几篇。
- **英文文献只保证"存在"，不保证"结论"。** Elsevier 等出版商不向 API 提供摘要，脚本对这类文献只做标题级描述，不替它断言研究结论。

## 合规与免责

- 脚本只读取公开可访问的页面与开放 API，不绕过任何付费墙。
- 中文库部分请遵守目标站点的 robots 与服务条款，控制频率、仅供个人学术检索使用。
- 本项目不存储、不分发任何论文全文。
- 引用的准确性最终由使用者负责，工具只负责"不让你引用不存在的东西"。

## License

MIT