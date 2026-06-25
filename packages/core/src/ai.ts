import { createConservativePlan } from "./fixtures.js";
import { applyWeightRecommendations, recommendWeightForExercise } from "./planning.js";
import { getCurrentExercise, getCurrentTarget } from "./stateMachine.js";
import type {
  AiAdjustmentSuggestion,
  AiFeedbackOption,
  AiPlanDraft,
  AiSuggestionAudit,
  FeedbackKind,
  PlanningContext,
  WorkoutPlan,
  WorkoutSession
} from "./types.js";

export interface AiProvider {
  name: string;
  draftPlan: (context: PlanningContext) => Promise<unknown> | unknown;
  draftFeedbackOptions: (session: WorkoutSession) => Promise<unknown> | unknown;
  draftAdjustmentSuggestion: (session: WorkoutSession) => Promise<unknown> | unknown;
}

export interface AiDraftResult<T> {
  value: T;
  audit: Omit<AiSuggestionAudit, "id" | "at">;
}

const allowedFeedbackKinds: FeedbackKind[] = ["completed", "not_followed", "too_easy", "too_hard", "pain", "skip", "note"];

function fallbackPlanDraft(context: PlanningContext): AiPlanDraft {
  const templatePlan = createConservativePlan(context.checkIn);
  const recommendations = templatePlan.exercises.map((exercise) =>
    recommendWeightForExercise({ exercise, history: context.exerciseHistory, inventory: context.equipmentInventory })
  );
  const plan = applyWeightRecommendations(templatePlan, recommendations);
  const missingEquipment = context.equipmentInventory.items.filter((item) => !item.available).map((item) => item.name);

  return {
    plan,
    assumptions: [
      "当前仍使用模板计划生成器，未来可替换为真实大模型。",
      context.equipmentInventory.notes ?? "器材档案尚未完全确认。"
    ],
    questions: missingEquipment.length > 0 ? [`这些器材暂不可用：${missingEquipment.join("、")}。`] : [],
    coachMessage: `根据今日状态、器材档案和历史表现生成计划草稿：${plan.focus}。请确认后开始。`,
    recommendations
  };
}

function fallbackFeedbackOptions(session: WorkoutSession): AiFeedbackOption[] {
  const exercise = getCurrentExercise(session);
  const baseId = exercise?.exerciseId ?? "current";
  const shoulderOption =
    exercise?.category === "push"
      ? [
          {
            id: `${baseId}_shoulder_uncertain`,
            kind: "note" as const,
            label: "肩膀发力不确定",
            message: "肩膀发力不确定",
            priority: 20
          }
        ]
      : [];

  return [
    ...shoulderOption,
    {
      id: `${baseId}_tempo_unstable`,
      kind: "note",
      label: "节奏不稳",
      message: "节奏不稳",
      priority: 30
    },
    {
      id: `${baseId}_range_uncertain`,
      kind: "note",
      label: "动作幅度不确定",
      message: "动作幅度不确定",
      priority: 40
    }
  ];
}

function fallbackAdjustmentSuggestion(session: WorkoutSession): AiAdjustmentSuggestion {
  const feedback = session.feedbackEvents.at(-1);
  const adjustment = session.adjustments.at(-1);
  const target = getCurrentTarget(session);
  const exercise = getCurrentExercise(session);
  const adjustedTargetSets = adjustment?.after.targetSets;
  const adjustedTarget = Array.isArray(adjustedTargetSets) ? adjustedTargetSets[0] : undefined;
  const targetRecord = typeof adjustedTarget === "object" && adjustedTarget !== null ? adjustedTarget : target;

  return {
    kind: "adjustment_suggestion",
    reason: feedback?.kind ?? "note",
    target: {
      exerciseName: exercise?.name ?? feedback?.exerciseName ?? "current exercise",
      setIndex: target?.setIndex ?? feedback?.setIndex ?? 1
    },
    suggestedChange: {
      reps: "targetReps" in (targetRecord ?? {}) ? Number(targetRecord?.targetReps) : undefined,
      weight: "targetWeight" in (targetRecord ?? {}) ? Number(targetRecord?.targetWeight) : undefined,
      restSeconds: "restSeconds" in (targetRecord ?? {}) ? Number(targetRecord?.restSeconds) : undefined,
      stop: feedback?.kind === "pain" ? true : undefined
    },
    coachMessage: session.coachMessages.at(-1)?.text ?? "先按规则教练的保守建议执行。"
  };
}

function validateFeedbackOptions(output: unknown): { value?: AiFeedbackOption[]; errors: string[] } {
  if (!Array.isArray(output)) {
    return { errors: ["feedback options output must be an array"] };
  }

  const errors: string[] = [];
  const options: AiFeedbackOption[] = [];
  output.slice(0, 4).forEach((item, index) => {
    if (!item || typeof item !== "object") {
      errors.push(`option ${index} must be an object`);
      return;
    }
    const candidate = item as Record<string, unknown>;
    if (typeof candidate.id !== "string" || candidate.id.length === 0) {
      errors.push(`option ${index} id is required`);
    }
    if (typeof candidate.label !== "string" || candidate.label.length === 0) {
      errors.push(`option ${index} label is required`);
    }
    if (!allowedFeedbackKinds.includes(candidate.kind as FeedbackKind)) {
      errors.push(`option ${index} kind is invalid`);
    }
    if (errors.length === 0 || options.length < index) {
      options.push({
        id: String(candidate.id),
        kind: candidate.kind as FeedbackKind,
        label: String(candidate.label),
        message: typeof candidate.message === "string" ? candidate.message : String(candidate.label),
        priority: typeof candidate.priority === "number" ? candidate.priority : 50
      });
    }
  });

  if (options.length === 0) {
    errors.push("at least one feedback option is required");
  }

  return errors.length > 0 ? { errors } : { value: options, errors: [] };
}

function validateWorkoutPlan(plan: unknown): { value?: WorkoutPlan; errors: string[] } {
  if (!plan || typeof plan !== "object") {
    return { errors: ["plan must be an object"] };
  }
  const candidate = plan as Partial<WorkoutPlan>;
  const errors: string[] = [];
  if (typeof candidate.focus !== "string" || candidate.focus.length === 0) {
    errors.push("plan.focus is required");
  }
  if (typeof candidate.estimatedDurationMinutes !== "number") {
    errors.push("plan.estimatedDurationMinutes is required");
  }
  if (!Array.isArray(candidate.exercises) || candidate.exercises.length === 0) {
    errors.push("plan.exercises must be a non-empty array");
  }
  for (const [index, exercise] of (candidate.exercises ?? []).entries()) {
    if (!exercise.exerciseId || !exercise.name || !Array.isArray(exercise.targetSets)) {
      errors.push(`exercise ${index} is invalid`);
    }
  }
  return errors.length > 0 ? { errors } : { value: candidate as WorkoutPlan, errors: [] };
}

function validatePlanDraft(output: unknown): { value?: AiPlanDraft; errors: string[] } {
  if (!output || typeof output !== "object") {
    return { errors: ["plan draft must be an object"] };
  }
  const candidate = output as Partial<AiPlanDraft>;
  const plan = validateWorkoutPlan(candidate.plan);
  const errors = [...plan.errors];
  if (!Array.isArray(candidate.assumptions)) {
    errors.push("assumptions must be an array");
  }
  if (!Array.isArray(candidate.questions)) {
    errors.push("questions must be an array");
  }
  if (typeof candidate.coachMessage !== "string" || candidate.coachMessage.length === 0) {
    errors.push("coachMessage is required");
  }
  if (!Array.isArray(candidate.recommendations)) {
    errors.push("recommendations must be an array");
  }
  if (errors.length > 0 || !plan.value) {
    return { errors };
  }
  return {
    errors: [],
    value: {
      plan: plan.value,
      assumptions: candidate.assumptions as string[],
      questions: candidate.questions as string[],
      coachMessage: candidate.coachMessage as string,
      recommendations: candidate.recommendations as AiPlanDraft["recommendations"]
    }
  };
}

function validateAdjustmentSuggestion(
  session: WorkoutSession,
  output: unknown
): { value?: AiAdjustmentSuggestion; errors: string[] } {
  if (!output || typeof output !== "object") {
    return { errors: ["adjustment suggestion must be an object"] };
  }
  const candidate = output as Record<string, unknown>;
  const errors: string[] = [];
  const latestFeedback = session.feedbackEvents.at(-1);
  const target = getCurrentTarget(session);
  const suggestedChange = candidate.suggestedChange as Record<string, unknown> | undefined;

  if (candidate.kind !== "adjustment_suggestion") {
    errors.push("kind must be adjustment_suggestion");
  }
  if (!allowedFeedbackKinds.includes(candidate.reason as FeedbackKind)) {
    errors.push("reason is invalid");
  }
  if (latestFeedback && candidate.reason !== latestFeedback.kind) {
    errors.push("reason must match the latest user feedback");
  }
  if (!suggestedChange || typeof suggestedChange !== "object") {
    errors.push("suggestedChange is required");
  }
  if (typeof candidate.coachMessage !== "string" || candidate.coachMessage.length === 0) {
    errors.push("coachMessage is required");
  }

  const reps = typeof suggestedChange?.reps === "number" ? suggestedChange.reps : undefined;
  if (target?.targetReps && reps !== undefined && reps > Math.ceil(target.targetReps * 1.25)) {
    errors.push("reps increase is too aggressive");
  }
  const weight = typeof suggestedChange?.weight === "number" ? suggestedChange.weight : undefined;
  if (target?.targetWeight && weight !== undefined && weight > Number((target.targetWeight * 1.2).toFixed(1))) {
    errors.push("weight increase is too aggressive");
  }
  if (latestFeedback?.kind === "pain" && suggestedChange?.stop !== true) {
    errors.push("pain feedback must suggest stopping");
  }

  if (errors.length > 0) {
    return { errors };
  }

  const rawTarget = candidate.target as Record<string, unknown> | undefined;
  return {
    value: {
      kind: "adjustment_suggestion",
      reason: candidate.reason as FeedbackKind,
      target: {
        exerciseName: String(rawTarget?.exerciseName ?? latestFeedback?.exerciseName ?? "current exercise"),
        setIndex: Number(rawTarget?.setIndex ?? latestFeedback?.setIndex ?? target?.setIndex ?? 1)
      },
      suggestedChange: {
        reps,
        weight,
        restSeconds: typeof suggestedChange?.restSeconds === "number" ? suggestedChange.restSeconds : undefined,
        stop: suggestedChange?.stop === true ? true : undefined
      },
      coachMessage: String(candidate.coachMessage)
    },
    errors: []
  };
}

function audit<T>(params: {
  kind: AiSuggestionAudit["kind"];
  provider: string;
  status: AiSuggestionAudit["status"];
  rawOutput?: unknown;
  validationErrors?: string[];
  value: T;
}): AiDraftResult<T> {
  return {
    value: params.value,
    audit: {
      kind: params.kind,
      provider: params.provider,
      status: params.status,
      validationErrors: params.validationErrors ?? [],
      rawOutput: params.rawOutput
    }
  };
}

export function createTemplateAiProvider(): AiProvider {
  return {
    name: "template-ai",
    draftPlan: fallbackPlanDraft,
    draftFeedbackOptions: fallbackFeedbackOptions,
    draftAdjustmentSuggestion: fallbackAdjustmentSuggestion
  };
}

export async function draftPlanWithFallback(
  provider: AiProvider,
  context: PlanningContext
): Promise<AiDraftResult<AiPlanDraft>> {
  try {
    const rawOutput = await provider.draftPlan(context);
    const validated = validatePlanDraft(rawOutput);
    if (validated.value) {
      return audit({
        kind: "plan_draft",
        provider: provider.name,
        status: "accepted_for_display",
        rawOutput,
        value: validated.value
      });
    }
    return audit({
      kind: "plan_draft",
      provider: provider.name,
      status: "fallback_used",
      rawOutput,
      validationErrors: validated.errors,
      value: fallbackPlanDraft(context)
    });
  } catch (error) {
    return audit({
      kind: "plan_draft",
      provider: provider.name,
      status: "fallback_used",
      rawOutput: error instanceof Error ? error.message : error,
      validationErrors: ["provider failed"],
      value: fallbackPlanDraft(context)
    });
  }
}

export async function draftFeedbackOptionsWithFallback(
  provider: AiProvider,
  session: WorkoutSession
): Promise<AiDraftResult<AiFeedbackOption[]>> {
  try {
    const rawOutput = await provider.draftFeedbackOptions(session);
    const validated = validateFeedbackOptions(rawOutput);
    if (validated.value) {
      return audit({
        kind: "feedback_options",
        provider: provider.name,
        status: "accepted_for_display",
        rawOutput,
        value: validated.value
      });
    }
    return audit({
      kind: "feedback_options",
      provider: provider.name,
      status: "fallback_used",
      rawOutput,
      validationErrors: validated.errors,
      value: fallbackFeedbackOptions(session)
    });
  } catch (error) {
    return audit({
      kind: "feedback_options",
      provider: provider.name,
      status: "fallback_used",
      rawOutput: error instanceof Error ? error.message : error,
      validationErrors: ["provider failed"],
      value: fallbackFeedbackOptions(session)
    });
  }
}

export async function draftAdjustmentSuggestionWithFallback(
  provider: AiProvider,
  session: WorkoutSession
): Promise<AiDraftResult<AiAdjustmentSuggestion>> {
  try {
    const rawOutput = await provider.draftAdjustmentSuggestion(session);
    const validated = validateAdjustmentSuggestion(session, rawOutput);
    if (validated.value) {
      return audit({
        kind: "adjustment_suggestion",
        provider: provider.name,
        status: "accepted_for_display",
        rawOutput,
        value: validated.value
      });
    }
    return audit({
      kind: "adjustment_suggestion",
      provider: provider.name,
      status: "fallback_used",
      rawOutput,
      validationErrors: validated.errors,
      value: fallbackAdjustmentSuggestion(session)
    });
  } catch (error) {
    return audit({
      kind: "adjustment_suggestion",
      provider: provider.name,
      status: "fallback_used",
      rawOutput: error instanceof Error ? error.message : error,
      validationErrors: ["provider failed"],
      value: fallbackAdjustmentSuggestion(session)
    });
  }
}
