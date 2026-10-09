#!/usr/bin/env python3
"""Generate the fixed 10 genre x 12 scene material A/B evaluation contexts."""

from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "Tests/EndToEndTests/Fixtures/material_eval/contexts.json"
NAMESPACE = uuid.UUID("fb54cdaa-9d9a-51dc-b222-8ca136d27f59")

GENRES = {
    "dushi": {
        "label": "都市",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "临江城旧商圈",
        "base": "停业改造的白鹭百货顶层",
        "hero": "独立调查员林澈",
        "ally": "夜班编辑周遥",
        "faction": "澄明实业风控部",
        "goal": "查清一笔被拆散到多家空壳公司的旧账",
        "rule": "口头承诺不算证据，门禁、票据与公开记录才能改变各方立场",
        "clue": "一张时间戳错位的停车凭证和一份删去经办人的会议纪要",
    },
    "gufeng": {
        "label": "古风",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "雁回州城南驿馆",
        "base": "临水的听雨别院",
        "hero": "代人递状的沈砚",
        "ally": "掌灯侍女阿蘅",
        "faction": "州府盐铁案巡检司",
        "goal": "把失踪账册送到愿意复查旧案的御史手中",
        "rule": "拜帖、印信与席次都代表身份，越礼行事会立刻引来盘问",
        "clue": "半枚驿馆火漆、一页受潮的盐引和城门换防时辰",
    },
    "kehuan": {
        "label": "科幻",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "木卫四晨昏环站",
        "base": "废弃的低温生物舱区",
        "hero": "维修领航员岑昼",
        "ally": "协议工程师祁蓝",
        "faction": "环站自治算法审计组",
        "goal": "确认失控导航为何把补给船引向封锁轨道",
        "rule": "舱门、算力与空气配额都有签名日志，绕过权限必然付出资源代价",
        "clue": "一段提前七秒出现的航迹回声和被手工覆写的舱压曲线",
    },
    "lishi": {
        "label": "历史",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "朔宁关外粮台",
        "base": "旧烽燧下的军需帐",
        "hero": "随军书吏顾循",
        "ally": "押粮队正韩七",
        "faction": "行营转运使衙门",
        "goal": "查明冬粮在入关前短少的真正环节",
        "rule": "文牒、关防与军令决定通行，擅离队列会被视作逃役或通敌",
        "clue": "两种墨色的仓单、缺角的关防拓印和一匹未登记的驮马",
    },
    "wuxia": {
        "label": "武侠",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "栖霞渡口",
        "base": "临江的破旧镖局",
        "hero": "停剑三年的镖师陆停舟",
        "ally": "药铺学徒苏叶",
        "faction": "掌控水路的鸣沙盟",
        "goal": "护送一封能洗清旧案的证词越过三处封渡",
        "rule": "江湖名帖能换来一次信任，拔剑则会把旁观者也卷入恩怨",
        "clue": "断在鞘中的青钢针、逆水而来的空舟和一枚旧镖旗铜扣",
    },
    "wuxianliu": {
        "label": "无限流",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "编号零四七的闭馆剧院",
        "base": "只在整点亮灯的后台化妆间",
        "hero": "第三次进入副本的许知返",
        "ally": "记忆残缺的队友唐禾",
        "faction": "佩戴白面具的巡场人",
        "goal": "在终场钟响前找出哪条舞台规则被人篡改",
        "rule": "广播规则可能真假混杂，违反真规则会失去记忆而非立即死亡",
        "clue": "多出一人的演员表、倒走的后台时钟和不会映出观众的镜面",
    },
    "xianxia": {
        "label": "仙侠",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "照雪山问心台",
        "base": "封存百年的藏星洞府",
        "hero": "灵脉受损的外门弟子闻溪",
        "ally": "守炉灵童鹤九",
        "faction": "执掌试炼名册的玄衡峰",
        "goal": "证明失踪灵泉并非自己盗取并找回山门水脉",
        "rule": "誓印能辨真意却不能还原事实，强行御剑会加重灵脉裂伤",
        "clue": "沾着异峰松脂的玉符、逆流的灵泉和一缕不属本门的剑意",
    },
    "xiaoyuan": {
        "label": "校园",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "南岚中学旧礼堂",
        "base": "广播社闲置的器材室",
        "hero": "校刊摄影记者乔沐",
        "ally": "学生会干事夏栀",
        "faction": "筹备校庆的年级委员会",
        "goal": "弄清竞赛名单为何在公示前被悄悄替换",
        "rule": "门卡、值日表与社团借用单都有记录，公开指控会影响同学关系",
        "clue": "一张裁切过的合影、午夜上传的广播稿和被借走的备用门卡",
    },
    "xihuan": {
        "label": "西幻",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "灰鲸港外城",
        "base": "铸钟人留下的潮汐塔",
        "hero": "见习誓约师伊诺",
        "ally": "会辨认古符的矮人米娅",
        "faction": "垄断航标火种的银帆议会",
        "goal": "在黑潮抵港前修复被人为熄灭的古老航标",
        "rule": "魔法誓言必有对价，未获许可召唤元素会惊动城墙上的猎法钟",
        "clue": "不受潮的龙鳞纸、少一笔的火种契文和向陆地游动的磷光鱼群",
    },
    "xuanyi": {
        "label": "悬疑",
        "opening_title": "入局",
        "opening_summary": "",
        "place": "停运的北岬夜车站",
        "base": "封条未拆的失物招领室",
        "hero": "民俗播客作者程雾",
        "ally": "最后一班值守员罗棠",
        "faction": "拒绝重启调查的线路管理处",
        "goal": "还原七年前末班车空驶记录背后的失踪事件",
        "rule": "证词会随提问方式改变，只有时刻表、录音底噪与实物位置可交叉验证",
        "clue": "没有编号的寄存牌、提前响起的进站铃和被剪掉十秒的值班录音",
    },
}

SCENES = {
    "duizhi": ("对峙", "关键知情者当面否认旧证词，旁观者正在判断谁先失去可信度", "把矛盾压到可核验的一项事实上，或暂时退让以换取对方暴露更多破绽"),
    "tansuo": ("探索", "一条平时封闭的通道意外开启，但环境正在逐步变得不可停留", "先确认退路再深入，或冒险抢在封闭前取得核心物证"),
    "gaobai": ("告白", "同伴在压力下说出长期隐瞒的情感与动机，现有合作关系因此动摇", "正面回应并承担关系变化，或先追问其隐瞒是否影响眼前任务"),
    "taowang": ("逃亡", "追捕者封住正门并开始逐区排查，安全窗口只剩很短时间", "利用熟悉的隐蔽路线撤离，或制造足以转移追兵的高风险动静"),
    "liangnan": ("两难", "救下眼前的人会失去唯一追查窗口，继续任务则可能留下无法弥补的后果", "明确选择要保护的对象，并让被放弃的一端产生真实代价"),
    "shenfen": ("身份", "一件旧物证明主角使用的姓名并非最初身份，盟友要求立即解释", "公开可验证的部分换取信任，或隐瞒核心事实并接受后续审查"),
    "tanpan": ("谈判", "对方握有必需资源却提出附带条件，双方都担心先让步会失去筹码", "交换可撤回的小承诺试探底线，或展示证据迫使条件重新定价"),
    "xinren": ("信任", "新盟友提供了一条能绕过封锁的办法，但其经历存在无法解释的空白", "给出受控权限验证诚意，或暗中设置不会伤及对方的验证点"),
    "fuchou": ("复仇", "旧案责任人突然落单，主角拥有报复机会却还缺最后一段证据", "立刻追究个人代价，或压住怒意把对方变成揭开全案的证人"),
    "xisheng": ("牺牲", "维持通道需要有人留下承担不可逆损失，其他人才能带着证据离开", "寻找分摊代价的新方案，或由最了解风险的人主动留下并说明理由"),
    "zhenxiang": ("真相", "多条矛盾线索突然指向同一解释，但承认它会推翻此前最信任的证词", "当场复核关键物证，或先保护知情者再公开会引发动荡的结论"),
    "lichang": ("立场", "两个长期合作的阵营要求主角公开站队，中立已经会被双方视为背叛", "选择更符合既有承诺的一方，或提出可执行的第三方案并承担两边压力"),
}


def stable_uuid(name: str) -> str:
    return str(uuid.uuid5(NAMESPACE, name))


def bounded_lore(text: str, fallback: str) -> str:
    while len(text) < 80:
        text += fallback
    if len(text) > 150:
        raise ValueError(f"lore entry is {len(text)} chars: {text}")
    return text


def make_context(genre: str, scene: str) -> dict:
    g = dict(GENRES[genre])
    g["opening_summary"] = g["goal"]
    scene_label, situation, decision = SCENES[scene]
    context_id = f"{genre}-{scene}"
    plot_id = f"plot-{genre}-{scene}"
    next_plot_id = f"plot-{genre}-{scene}-next"
    lore = [
        bounded_lore(
            f"{g['place']}以{g['label']}题材特有的秩序维持日常。{g['hero']}暂住在{g['base']}，目标是{g['goal']}。"
            f"{g['faction']}控制关键通道；当地人默认{g['rule']}。",
            "任何越界行动都会留下可追查的后果。",
        ),
        bounded_lore(
            f"当前局势是“{scene_label}”：{situation}。{g['ally']}与主角共同到场，但只掌握部分事实。"
            f"可行方向是{decision}，两种选择都会改变后续合作与风险。",
            "旁观者会记住主角此刻的取舍。",
        ),
        bounded_lore(
            f"已知线索包括{g['clue']}。这些线索只证明行动顺序存在异常，不能单独证明幕后责任。"
            f"{g['hero']}目前仍可联系{g['ally']}，但若惊动{g['faction']}，对方会先封存记录再要求说明。",
            "线索必须交叉验证，传闻不能直接当成事实。",
        ),
    ]
    entries = []
    for index, content in enumerate(lore, 1):
        entries.append(
            {
                "id": f"{context_id}-lore-{index}",
                "title": ["地点与规则", f"当前{scene_label}局势", "人物与线索"][index - 1],
                "content": content,
                "activation_keys": [],
                "enabled": True,
                "always_active": True,
                "hidden": False,
                "category_id": None,
            }
        )

    first_patch = {"plot": {"node": 1}, "location": g["place"], "scene": scene}
    second_patch = {"pressure": "rising", "ally": g["ally"]}
    return {
        "id": context_id,
        "genre": genre,
        "scene": scene,
        "user_message": f"我看向{g['ally']}，决定先针对眼前的{scene_label}局势采取一个具体行动。",
        "worldbook": {
            "title": f"{g['label']}·{scene_label}固定评测世界",
            "lorebook": {
                "format_version": 1,
                "id": stable_uuid(f"lorebook:{context_id}"),
                "title": f"{g['label']}·{scene_label}评测 Lorebook",
                "entries": entries,
                "categories": [],
            },
            "plotline": {
                "nodes": [
                    {
                        "id": plot_id,
                        "title": f"{scene_label}发生",
                        "summary": situation + "。",
                        "order": 1,
                        "chapterOrdinal": 0,
                    },
                    {
                        "id": next_plot_id,
                        "title": "代价显现",
                        "summary": "主角的选择改变同盟关系，并使隐藏线索进入下一阶段。",
                        "order": 2,
                        "chapterOrdinal": 1,
                    },
                ],
                "source": "synthetic-material-eval",
                "generated_at": "2026-08-31T00:00:00Z",
            },
            "material_profile": {
                "schema_version": 1,
                "primary_genre": genre,
                "secondary_genres": [],
                "confidence": 0.9,
                "source": "fixed-evaluation-fixture",
                "evidence": [f"合成世界按{g['label']}规则设计", f"当前剧情节点明确映射到{scene_label}"],
                "plot_scene_map": {plot_id: [scene]},
                "beat_scene_map": {f"beat-{context_id}": [scene]},
            },
        },
        "snapshot": {
            "initial_state": {"plot": {"node": 1}, "location": g["place"], "scene": scene},
            "turns": [
                {
                    # 与生产路径一致：首回合用户消息是开局指令（StoryTurnEngine.openingPrompt），
                    # 否则历史回放缺少格式压力，模型倾向直接输出无标签散文
                    "user_message": (
                        "（系统指令：玩家刚刚进入这个世界，还没有采取任何行动。请直接输出开场叙事："
                        f"故事必须从原著主线开篇开始——「{g['opening_title']}」：{g['opening_summary']}"
                        "把玩家放进这个开端场景里，交代其身份、处境与眼前正在发生的事，"
                        "结尾留给玩家行动的空间，并给出原著方向与创新方向的行动选项。不要替玩家做关键选择，不要输出旁白说明。）"
                    ),
                    "narrative": f"{g['hero']}抵达{g['place']}，在{g['base']}附近发现有人提前翻动过现场。{g['ally']}示意不要立刻声张。",
                    "choices": ["检查现场留下的痕迹", "询问同伴为何保持沉默"],
                    "state_patch": first_patch,
                    "beat_id": f"beat-{context_id}-arrival",
                },
                {
                    "user_message": "我先核对最容易被忽略的那条线索。",
                    "narrative": f"核对结果让{g['clue']}同时进入视野，{g['faction']}的人也正在接近。局势转为必须立即处理的{scene_label}时刻。",
                    "choices": ["留下来处理眼前冲突", "带着线索转移到安全地点"],
                    "state_patch": second_patch,
                    "beat_id": f"beat-{context_id}",
                },
            ],
        },
    }


def build_payload() -> dict:
    contexts = [
        make_context(genre, scene)
        for genre in GENRES
        for scene in SCENES
    ]
    assert len(contexts) == 120
    assert len({item["id"] for item in contexts}) == 120
    return {
        "schema_version": 1,
        "fixture_version": "material-eval-v1",
        "contexts": contexts,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true", help="fail if the checked-in fixture differs")
    args = parser.parse_args()
    encoded = json.dumps(build_payload(), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.check:
        current = args.output.read_text(encoding="utf-8") if args.output.exists() else ""
        if current != encoded:
            raise SystemExit(f"fixture is stale: run {Path(__file__).name}")
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(encoded, encoding="utf-8")
    print(f"wrote 120 contexts to {args.output}")


if __name__ == "__main__":
    main()
