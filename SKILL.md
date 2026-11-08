---
name: paper-citation-guard
description: 论文引用防伪核验。凡是要给出参考文献、核查某篇论文是否真实存在、从文献页面生成规范引用（GB/T 7714 或 APA），都必须先加载本技能。每条文献必须绑定一个真实可访问的链接，链接和元数据全部来自实际抓取的页面，禁止凭记忆生成。
---

# 论文引用防伪

**一句话：先有页面，才有引用。** 没有抓到页面的文献，不许出现在答复里 —— 哪怕你"很确定"它存在。

## 换一台机器，第一件事是自检

```bash
python3 <技能目录>/scripts/refcheck.py doctor -InitConfig        # 任意系统，首选
<技能目录>/scripts/refcheck.sh doctor -InitConfig                # macOS/Linux 快捷入口
pwsh -NoProfile -File <技能目录>/scripts/refcheck.ps1 doctor -InitConfig   # Windows 备选
```

**首选 Python 3**：只用标准库，macOS 和 Linux 自带，不需要装任何东西。
机器上没有 Python 时退回 **PowerShell 7**（`pwsh`，macOS `brew install --cask powershell`，Ubuntu `sudo snap install powershell --classic`）。
两个实现共用同一份 `providers.json` / `config.json` / `cache/`，可以混着用，行为一致。都没有时脚本会直接告诉你装哪个，不会静默失败。

下面示例统一写 `refcheck.py`；换成 `.sh` 或 `.ps1`，参数完全一样。

它会逐个探活 22 个数据源，打印「可连接 / 缺 API key / 连不上 / 未启用」，并把缺的配置项列出来。首次运行会用 `-InitConfig` 生成 `config.json` 模板，填完再跑一次 `doctor` 确认。

**不要假设"上次能连，这次也能连"。** 每换一台机器、每换一个网络环境，都先跑 doctor，并且把结果如实告诉用户 —— 这是"覆盖声明"的依据。

配置文件长这样（`config.json`，与 `providers.json` 同目录）：

```json
{
  "email": "you@example.com",
  "providers": {
    "semanticscholar": { "apiKey": "" },
    "core": { "apiKey": "" },
    "scopus": { "apiKey": "" }
  }
}
```

`email` 填上就能进 CrossRef 的 polite pool、并解锁 Unpaywall。API key 留空的库会被自动跳过，不会拖慢检索。

## 五条硬规则

1. **无链接不引用。** 每条参考文献后面必须跟一个能点开的地址，且必须是论文落地页或 DOI 解析地址。百度/必应/谷歌的搜索结果页不算链接。
2. **字段只抄不补。** 题名、作者、年份、刊名、卷、期、页码只能取自脚本输出。脚本没给的写「页面未提供」，绝不按常识补齐（页码和卷号最容易编）。
3. **相似度低于 0.80 就是没查到。** `WEAK` / `NOT_FOUND` 一律按"查不到"处理，不许拿一篇相近的顶上。
4. **二手引用要原样核。** 别人参考文献里抄来的条目，按原题名、原作者、原年份去核；核不到就说"疑似不存在"，并列出查过哪些库。
5. **每次交付必须带覆盖声明。** 格式见下。没有覆盖声明 = 暗示"我查遍了全世界"，那是另一种撒谎。

## 四种用法

| 场景 | 命令 |
|---|---|
| 只有标题/作者 | `verify -Query "标题或 作者 年份"` |
| 只有 DOI | `verify -Doi 10.xxxx/xxxxx` |
| 只有页面链接 | `page -Url https://...` |
| 按主题找文献 | `search "关键词" -Limit 8` |
| 在某刊某几年里找 | `search "反馈" -In 外语界 -Since 2022` |
| 翻某刊某期目录 | `toc -Journal 外语界 -Year 2023` |
| 环境自检 | `doctor` |

常用开关：

- `-Since 2022` / `-Until 2026`：年份过滤（走各库原生 filter，不是事后筛）
- `-Sources openalex,doaj`：指定只用哪几个库
- `-WithAbstract`：尽量取摘要（OpenAlex 的 OA 记录、Semantic Scholar、CORE 有效）
- `-Style apa|both`：换引用格式
- `-Json`：机器可读

默认检索源是 OpenAlex + CrossRef + Europe PMC + DOAJ + arXiv；加 `-Cn` 再挂上知网。

### 中文文献

```
refcheck.py search "二语写作反馈" -Cn -Limit 6
```

中文库没有公开检索接口，走的是「百度找落地页 → 抓知网页面」的路子：百度被限流时脚本会自动切 360。拿到的 `LEAD` 条目只是线索，必须再 `page -Url` 过一遍才算核到。

知网页面**不显示页码**，这是页面本身的缺陷。引用就写 `外语界, 2023(3).`，并在表里注明"页码页面未提供"。

### 中文的确定性打法：按刊枚举目录

万方/维普没有可用接口，但知网的文章地址是**连续编号**：

```
CJFDTotal-<刊号4位><年4位><期2位><序号3位>.htm     例：CJFDTotal-WYJY202303007.htm
```

于是一期就是一个连续的号段，逐号探过去就能把整期目录连作者一起扒出来。这就是 `toc`：

```
refcheck.py toc -Journal 外语界 -Year 2023          # 整年（自动探到空期为止）
refcheck.py toc -Journal WYJY -Year 2023 -Issue 3   # 单期
refcheck.py toc -Journal 外语界 -Year 2023 -Match 反馈   # 年内按关键词筛
```

内置刊号：外语界 WYJY、外语电化教学 WYDH、现代外语 XDWY、解放军外国语学院学报 JFJW、齐鲁师范学院学报 SDJX、成都师范学院学报 SJXB。其他刊物直接传刊号即可。

**在某刊某几年里按主题找**（写综述时最常用）：

```
refcheck.py search "反馈" -In 外语界 -Since 2022
refcheck.py search "写作 评价" -In 外语电化教学 -Since 2023 -Until 2025
```

多个关键词用空格或「、」分隔，命中任意一个即算（题名和作者都匹配）；`或 / 和 / 与 / and / or` 会被忽略。不写 `-Since` 默认查近五年。结果每一条都带知网链接和 GB/T 引用，可直接进参考文献表。

**代价与注意事项**：

- 每期约 13–15 篇，单期要发 15 次左右请求，整年约 2 分钟。脚本按 1.1 秒起步节流，撞到 403 就自动拉长间隔（最长 4 秒）并档 6 秒重试。
- 结果缓存在 `cache/<刊号>-<年>-<期>.json`，30 天内重复查询是秒回。要强制刷新加 `-NoCache`。
- **知网会给限流**。某一期没抓到，脚本会明确警告「共 N 期没抓到，结果不完整」，并且**不会把半截数据写进缓存**。过几分钟重跑即可，已缓存的期不会重复抓。
- 这条路上的每一条都是知网真实页面，标题和作者直接来自页面 —— 满足"有链接才引用"的规则。

**什么时候用它**：需要某一期的完整目录、或要在某刊某年找某个主题但搜索引擎搜不到时。这比 `search -Cn` 可靠，因为它不依赖搜索引擎索引。

## 检索范围（22 个源，16 个可用）

**已实现检索的（15 个）**：OpenAlex、CrossRef、Europe PMC、Semantic Scholar\*、CORE\*、OpenAIRE、Scopus\*、ScienceDirect\*、Springer\*、Web of Science\*、DOAJ、DataCite、PubMed\*、arXiv、中国知网。

**只做定位不做检索（1 个）**：Unpaywall —— 按 DOI 查有没有免费全文，配了 email 才会在结果里多一行「免费全文」。

**没有公开检索接口的（6 个）**：IEEE Xplore、JSTOR、PubMed（SSL 层可能被墙）、万方、维普、国家哲社文献中心。这几个**不要假装查过**，`-Sources` 里选了它们，覆盖声明会写明「无公开检索接口」。

带 `*` 的需要 API key 或机构订阅，在 `config.json` 里填；没填的会被自动跳过并在覆盖声明里标「缺 key」。

默认组合：OpenAlex + CrossRef + Europe PMC + DOAJ + arXiv；加 `-Cn` 再挂知网。

## 输出格式

核到的：

```
[1] ✔ 徐锦芬, 刘文波. 大中小学外语教材思政内容一体化建设研究[J]. 外语界, 2023(3).
    https://www.cnki.com.cn/Article/CJFDTotal-WYJY202303003.htm
```

核不到的必须单独列出，不许悄悄删掉：

```
[3] ✘ 未核到：梁茂成. 大语言模型对外语教学与研究的挑战与应对[J]. 外语界, 2023(3): 10-16.
    已查：OpenAlex / CrossRef / 知网目录，均无此题名。疑似不存在或引用信息有误。
```

每次交付末尾两行：

```
核验：verified=5  未核到=1
覆盖：已查 OpenAlex、CrossRef、Europe PMC；未查 Scopus（缺 key）、CORE（缺 key）
```

## 核不到的时候怎么办

1. 换关键词（去副标题、换同义表述、只留核心概念）再 `search`。
2. 加 `-Cn` 走中文库。
3. 跑一次 `doctor`，确认不是"库连不上"被误当成"文献不存在"。
4. 给真实存在的替代文献，并明确标注"这不是你引的那篇"。

## 不要做的事

- 不要用记忆里的引用格式直接写参考文献 —— 必须先跑脚本。
- 不要把"高被引""经典文献"当作存在的证据。
- 不要用 `WEAK` 条目凑数。
- 不要在缺 key 的库上假装检索过。
- 不要写"已核实"却不给链接 —— 链接就是核实本身。