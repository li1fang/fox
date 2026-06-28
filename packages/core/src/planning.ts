import type {
  EquipmentInventory,
  ExerciseBlock,
  ExerciseHistorySnapshot,
  SetTarget,
  WeightRecommendation,
  WorkoutPlan
} from "./types.js";

export function createDefaultEquipmentInventory(now = new Date().toISOString()): EquipmentInventory {
  return {
    updatedAt: now,
    notes:
      "家庭训练资源初版：两台主要固定器械，加哑铃、跑步、游泳、俯卧撑。器材知识先结构化登记，未来再做拍照识别或智能登记。",
    items: [
      {
        id: "multi_press_machine",
        name: "Multi Press Machine",
        nameCn: "多功能推举训练器",
        nameEn: "Multi Press Machine",
        kind: "machine",
        available: true,
        equipmentType: "固定轨迹力量器械",
        movementPatterns: ["推", "坐姿推举", "固定轨迹推举"],
        adjustments: {
          backPadPositions: 5,
          purpose: "通过调整靠背/坐姿角度，在胸推、上斜推举、肩推之间切换"
        },
        functions: [
          {
            id: "machine_chest_press",
            name: "Chest Press",
            nameCn: "坐姿胸推",
            nameEn: "Chest Press",
            category: "push",
            movementPatterns: ["推", "水平或轻微上斜推举"],
            mainMuscles: ["胸大肌"],
            secondaryMuscles: ["三角肌前束", "肱三头肌"],
            description: "坐姿胸推训练，推举轨迹接近水平或轻微上斜，主要训练胸大肌。"
          },
          {
            id: "machine_incline_press",
            name: "Incline Press",
            nameCn: "上斜推举",
            nameEn: "Incline Press",
            category: "push",
            movementPatterns: ["推", "上斜推举"],
            mainMuscles: ["上胸部", "胸大肌锁骨束"],
            secondaryMuscles: ["三角肌前束", "肱三头肌"],
            description: "通过调整靠背角度进行上斜推举，推举轨迹更偏向上方，主要刺激上胸。"
          },
          {
            id: "machine_shoulder_press",
            name: "Shoulder Press",
            nameCn: "坐姿肩推",
            nameEn: "Shoulder Press",
            category: "push",
            movementPatterns: ["推", "向上推举"],
            mainMuscles: ["三角肌前束", "三角肌中束"],
            secondaryMuscles: ["肱三头肌", "上胸部"],
            description: "较直立坐姿下进行向上推举，主要训练肩部推举力量。"
          }
        ],
        constraints: ["固定轨迹器械，动作变化主要依赖靠背/坐姿档位。", "具体重量档位和阻力曲线仍需实测确认。"],
        tags: ["home_gym", "push", "machine"],
        notes: "三合一推举器械，适合胸部、上胸、肩部训练。使用时根据目标动作调整靠背/坐姿档位。"
      },
      {
        id: "lat_pulldown_machine",
        name: "Lat Pulldown Machine",
        nameCn: "高位下拉训练器",
        nameEn: "Lat Pulldown Machine",
        kind: "machine",
        available: true,
        equipmentType: "固定力量器械",
        movementPatterns: ["拉", "垂直下拉"],
        functions: [
          {
            id: "lat_pulldown",
            name: "Lat Pulldown",
            nameCn: "高位下拉",
            nameEn: "Lat Pulldown",
            category: "pull",
            movementPatterns: ["拉", "垂直下拉"],
            mainMuscles: ["背阔肌"],
            secondaryMuscles: ["肱二头肌", "斜方肌中下束", "菱形肌"],
            description: "坐姿进行垂直下拉，主要训练背阔肌和上背拉力。"
          }
        ],
        constraints: ["仅支持垂直下拉。", "不支持标准水平划船。", "带多种把手附件，具体把手清单待补全。"],
        tags: ["home_gym", "pull", "machine"],
        notes: "高位下拉训练器，带多种把手附件；不能当作标准水平划船器使用。"
      },
      {
        id: "adjustable_dumbbells",
        name: "Dumbbells",
        nameCn: "哑铃",
        nameEn: "Dumbbells",
        kind: "dumbbell",
        available: true,
        weightUnit: "kg",
        minWeight: 2.5,
        maxWeight: 12.5,
        increment: 2.5,
        fixedWeights: [2.5, 5, 7.5, 10, 12.5],
        functions: [
          {
            id: "dumbbell_press_raise_curl_row",
            name: "General Dumbbell Strength Work",
            nameCn: "哑铃力量训练",
            nameEn: "General Dumbbell Strength Work",
            category: "other",
            movementPatterns: ["推", "拉", "侧平举", "弯举", "划船"],
            mainMuscles: ["胸", "肩", "背", "手臂"],
            description: "用于哑铃卧推、肩推、侧平举、弯举、单臂划船等家庭训练动作。"
          }
        ],
        constraints: ["重量范围来自旧训练记录，实际完整重量需要再次确认。"],
        tags: ["home_gym", "free_weight"],
        notes: "已知旧记录出现 2.5/5/7.5/10/12.5kg；是否还有更大重量待确认。"
      },
      {
        id: "running",
        name: "Running",
        nameCn: "跑步",
        nameEn: "Running",
        kind: "activity",
        available: true,
        functions: [
          {
            id: "running_cardio",
            name: "Running",
            nameCn: "跑步",
            nameEn: "Running",
            category: "cardio",
            movementPatterns: ["有氧", "下肢循环"],
            mainMuscles: ["心肺", "下肢"],
            description: "作为有氧训练、热身或恢复日训练选项。"
          }
        ],
        tags: ["cardio", "conditioning"],
        notes: "可作为有氧、热身、减脂或恢复训练选项；场地和天气条件待实际确认。"
      },
      {
        id: "swimming",
        name: "Swimming",
        nameCn: "游泳",
        nameEn: "Swimming",
        kind: "activity",
        available: true,
        functions: [
          {
            id: "swimming_cardio",
            name: "Swimming",
            nameCn: "游泳",
            nameEn: "Swimming",
            category: "cardio",
            movementPatterns: ["有氧", "全身循环"],
            mainMuscles: ["心肺", "背", "肩", "核心"],
            description: "作为低冲击有氧、恢复训练或独立训练日选项。"
          }
        ],
        tags: ["cardio", "low_impact"],
        notes: "可作为低冲击有氧和恢复训练选项；泳池可用性待按当天情况确认。"
      },
      {
        id: "push_up_bodyweight",
        name: "Push-up",
        nameCn: "俯卧撑",
        nameEn: "Push-up",
        kind: "bodyweight",
        available: true,
        functions: [
          {
            id: "push_up",
            name: "Push-up",
            nameCn: "俯卧撑",
            nameEn: "Push-up",
            category: "push",
            movementPatterns: ["推", "自重推"],
            mainMuscles: ["胸大肌"],
            secondaryMuscles: ["三角肌前束", "肱三头肌", "核心"],
            description: "无需器材的自重推类动作，可作为推举训练补充或替代。"
          }
        ],
        tags: ["bodyweight", "push"],
        notes: "可作为无器材推类训练、热身或补充动作。"
      }
    ]
  };
}

function roundToIncrement(weight: number, increment: number | undefined, preferDown = false): number {
  if (!increment || increment <= 0) {
    return Number(weight.toFixed(1));
  }
  const units = preferDown ? Math.floor(weight / increment) : Math.round(weight / increment);
  return Number((units * increment).toFixed(1));
}

function clampToEquipment(weight: number, exercise: ExerciseBlock, inventory: EquipmentInventory, preferDown = false): number {
  const dumbbell = inventory.items.find((item) => item.available && item.kind === "dumbbell");
  if (!dumbbell || exercise.targetSets.every((set) => set.weightUnit !== "kg")) {
    return Number(weight.toFixed(1));
  }
  const min = dumbbell.minWeight ?? weight;
  const max = dumbbell.maxWeight ?? weight;
  return Math.min(max, Math.max(min, roundToIncrement(weight, dumbbell.increment, preferDown)));
}

function isNegativeFeedback(kind: string): boolean {
  return kind === "pain" || kind === "not_followed" || kind === "too_hard" || kind === "skip";
}

export function recommendWeightForExercise(params: {
  exercise: ExerciseBlock;
  history: ExerciseHistorySnapshot[];
  inventory: EquipmentInventory;
}): WeightRecommendation {
  const { exercise, history, inventory } = params;
  const matching = history
    .filter((item) => item.exerciseId === exercise.exerciseId || item.exerciseName.toLowerCase() === exercise.name.toLowerCase())
    .sort((a, b) => new Date(b.occurredAt).getTime() - new Date(a.occurredAt).getTime());
  const latest = matching[0];
  const templateTarget = exercise.targetSets.find((target) => target.targetWeight !== undefined);

  if (!latest) {
    return {
      exerciseId: exercise.exerciseId,
      exerciseName: exercise.name,
      weight: templateTarget?.targetWeight,
      weightUnit: templateTarget?.weightUnit,
      reps: templateTarget?.targetReps,
      confidence: "low",
      source: "template",
      rationale: "没有同动作历史，先使用模板重量。"
    };
  }

  const lastWeightedSet = [...latest.sets].reverse().find((set) => set.weight !== undefined);
  const lastRepSet = [...latest.sets].reverse().find((set) => set.reps !== undefined);
  const hadNegativeFeedback = latest.feedbackKinds.some(isNegativeFeedback);
  const baseWeight = lastWeightedSet?.weight ?? templateTarget?.targetWeight;
  const suggested =
    baseWeight === undefined ? undefined : clampToEquipment(hadNegativeFeedback ? baseWeight * 0.9 : baseWeight, exercise, inventory, hadNegativeFeedback);

  return {
    exerciseId: exercise.exerciseId,
    exerciseName: exercise.name,
    weight: suggested,
    weightUnit: lastWeightedSet?.weightUnit ?? templateTarget?.weightUnit,
    reps: hadNegativeFeedback ? Math.max(1, Math.floor((lastRepSet?.reps ?? templateTarget?.targetReps ?? 8) * 0.9)) : lastRepSet?.reps ?? templateTarget?.targetReps,
    confidence: matching.length >= 3 ? "high" : "medium",
    source: "history",
    rationale: hadNegativeFeedback ? "最近同动作有风险反馈，推荐略微保守。" : "根据最近同动作完成情况推荐。"
  };
}

function applyRecommendationToTarget(target: SetTarget, recommendation: WeightRecommendation): SetTarget {
  return {
    ...target,
    targetReps: recommendation.reps ?? target.targetReps,
    targetWeight: recommendation.weight ?? target.targetWeight,
    weightUnit: recommendation.weightUnit ?? target.weightUnit,
    intensityNote: recommendation.rationale
  };
}

export function applyWeightRecommendations(
  plan: WorkoutPlan,
  recommendations: WeightRecommendation[]
): WorkoutPlan {
  const recommendationByExercise = new Map(recommendations.map((recommendation) => [recommendation.exerciseId, recommendation]));
  return {
    ...plan,
    exercises: plan.exercises.map((exercise) => {
      const recommendation = recommendationByExercise.get(exercise.exerciseId);
      if (!recommendation) {
        return exercise;
      }
      return {
        ...exercise,
        targetSets: exercise.targetSets.map((target) => applyRecommendationToTarget(target, recommendation))
      };
    })
  };
}
