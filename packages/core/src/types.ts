export type WorkoutRuntimeState =
  | "idle"
  | "planning"
  | "awaiting_approval"
  | "active_exercise"
  | "rest_timer"
  | "feedback"
  | "adapting"
  | "summary_pending"
  | "confirmed"
  | "cancelled"
  | "aborted";

export type CheckInLevel = "low" | "medium" | "high";
export type SleepQuality = "good" | "ok" | "poor";
export type HungerLevel = "not_hungry" | "somewhat_hungry" | "very_hungry";

export interface DailyCheckIn {
  sleep: SleepQuality;
  fatigue: CheckInLevel;
  hunger: HungerLevel;
  stress: CheckInLevel;
  painAreas: string[];
  availableMinutes: number;
}

export interface TempoPhase {
  phase: "lift" | "peak" | "lower" | "hold" | "rest";
  seconds: number;
  visual: "expand" | "vibrate" | "shrink" | "hold" | "idle";
}

export interface SetTarget {
  setIndex: number;
  targetReps?: number;
  targetDurationSeconds?: number;
  targetWeight?: number;
  weightUnit?: "kg" | "lb" | "bodyweight" | "machine_level";
  restSeconds: number;
  intensityNote?: string;
}

export interface SetRecord {
  setIndex: number;
  plannedSetIndex: number;
  status: "completed" | "partial" | "skipped" | "failed";
  reps?: number;
  weight?: number;
  weightUnit?: "kg" | "lb" | "bodyweight" | "machine_level";
  durationSeconds?: number;
  rpe?: number;
  pain: boolean;
  notes?: string;
  countingMethod: "manual" | "timer" | "accelerometer" | "pose_estimation";
}

export interface ExerciseBlock {
  exerciseId: string;
  name: string;
  category: "push" | "pull" | "legs" | "core" | "cardio" | "mobility" | "other";
  targetSets: SetTarget[];
  completedSets: SetRecord[];
  restSeconds: number;
  tempo: TempoPhase[];
  notes?: string;
}

export interface WorkoutPlan {
  focus: string;
  estimatedDurationMinutes: number;
  warmup: string;
  cooldown: string;
  safetyNotes: string;
  exercises: ExerciseBlock[];
}

export type EquipmentKind =
  | "dumbbell"
  | "barbell"
  | "kettlebell"
  | "pull_up_bar"
  | "bench"
  | "mat"
  | "machine"
  | "cardio"
  | "bodyweight"
  | "activity"
  | "other";

export interface EquipmentFunction {
  id: string;
  name: string;
  nameCn?: string;
  nameEn?: string;
  category?: ExerciseBlock["category"];
  movementPatterns?: string[];
  mainMuscles?: string[];
  secondaryMuscles?: string[];
  description?: string;
  setupNotes?: string[];
  constraints?: string[];
}

export interface EquipmentItem {
  id: string;
  name: string;
  nameCn?: string;
  nameEn?: string;
  kind: EquipmentKind;
  available: boolean;
  equipmentType?: string;
  movementPatterns?: string[];
  adjustments?: Record<string, unknown>;
  functions?: EquipmentFunction[];
  constraints?: string[];
  aliases?: string[];
  tags?: string[];
  weightUnit?: "kg" | "lb" | "machine_level";
  minWeight?: number;
  maxWeight?: number;
  increment?: number;
  fixedWeights?: number[];
  machineLevels?: number[];
  notes?: string;
}

export interface EquipmentInventory {
  items: EquipmentItem[];
  notes?: string;
  updatedAt?: string;
}

export interface BodyMeasurement {
  kind: "shoulder_width" | "chest" | "waist" | "hip" | "arm" | "thigh" | "body_weight" | "other";
  label: string;
  value: number;
  unit: "cm" | "kg" | "lb";
  measuredAt: string;
  notes?: string;
}

export interface UserProfile {
  sex?: "male" | "female" | "other" | "unknown";
  birthYear?: number;
  ethnicity?: string;
  heightCm?: number;
  weightKg?: number;
  preferredWeightUnit?: "kg" | "lb";
  activityBaseline?: {
    dailyStepsApprox?: number;
    recentTrainingStatus?: string;
    cardioBaseline?: string;
  };
  measurements?: BodyMeasurement[];
  notes?: string;
  updatedAt?: string;
}

export interface ExerciseHistorySnapshot {
  exerciseId?: string;
  exerciseName: string;
  occurredAt: string;
  sets: SetRecord[];
  feedbackKinds: FeedbackKind[];
}

export interface WeightRecommendation {
  exerciseId: string;
  exerciseName: string;
  weight?: number;
  weightUnit?: SetTarget["weightUnit"];
  reps?: number;
  confidence: "low" | "medium" | "high";
  source: "history" | "profile" | "template";
  rationale: string;
}

export interface PlanningContext {
  checkIn: DailyCheckIn;
  equipmentInventory: EquipmentInventory;
  exerciseHistory: ExerciseHistorySnapshot[];
  recentRiskSignals: string[];
}

export interface AiPlanDraft {
  plan: WorkoutPlan;
  assumptions: string[];
  questions: string[];
  coachMessage: string;
  recommendations: WeightRecommendation[];
}

export type FeedbackKind =
  | "completed"
  | "not_followed"
  | "too_easy"
  | "too_hard"
  | "pain"
  | "skip"
  | "note";

export interface AiFeedbackOption {
  id: string;
  kind: FeedbackKind;
  label: string;
  message?: string;
  priority: number;
}

export interface AiAdjustmentSuggestion {
  kind: "adjustment_suggestion";
  reason: FeedbackKind;
  target: {
    exerciseName: string;
    setIndex: number;
  };
  suggestedChange: {
    reps?: number;
    weight?: number;
    restSeconds?: number;
    stop?: boolean;
  };
  coachMessage: string;
}

export interface AiSuggestionAudit {
  id: string;
  at: string;
  kind: "feedback_options" | "adjustment_suggestion" | "summary_draft" | "plan_draft";
  provider: string;
  status: "accepted_for_display" | "rejected" | "fallback_used";
  validationErrors: string[];
  rawOutput?: unknown;
}

export interface FeedbackEvent {
  id: string;
  at: string;
  state: WorkoutRuntimeState;
  kind: FeedbackKind;
  kinds?: FeedbackKind[];
  exerciseName: string;
  setIndex: number;
  message?: string;
  messages?: string[];
}

export interface TimerEvent {
  id: string;
  at: string;
  kind:
    | "exercise_timer_started"
    | "exercise_timer_finished"
    | "rest_timer_started"
    | "rest_timer_finished"
    | "timer_extended"
    | "timer_cancelled";
  durationSeconds: number;
  target: string;
}

export interface Adjustment {
  id: string;
  at: string;
  reason: "not_followed" | "too_easy" | "too_hard" | "pain" | "time_constraint" | "manual";
  decidedBy: "rules" | "ai_suggestion" | "user";
  target: string;
  before: Record<string, unknown>;
  after: Record<string, unknown>;
}

export interface CoachMessage {
  id: string;
  at: string;
  role: "coach" | "system";
  state: WorkoutRuntimeState;
  text: string;
  source: "system" | "ai" | "template";
}

export interface PendingSetCompletion {
  exerciseIndex: number;
  setIndex: number;
  startedAt: string;
  finishedAt: string;
  record: SetRecord;
}

export interface RestTimer {
  startedAt: string;
  endsAt: string;
  durationSeconds: number;
  target: string;
}

export interface WorkoutSession {
  id: string;
  entryId?: string;
  status: WorkoutRuntimeState;
  checkIn?: DailyCheckIn;
  plan?: WorkoutPlan;
  currentExerciseIndex: number;
  currentSetIndex: number;
  activeSetStartedAt?: string;
  pendingSet?: PendingSetCompletion;
  restTimer?: RestTimer;
  feedbackEvents: FeedbackEvent[];
  timerEvents: TimerEvent[];
  adjustments: Adjustment[];
  coachMessages: CoachMessage[];
  aiAudits: AiSuggestionAudit[];
  summary?: string;
  startedAt?: string;
  endedAt?: string;
  createdAt: string;
  updatedAt: string;
}

export type WorkoutEvent =
  | { type: "SUBMIT_CHECK_IN"; checkIn: DailyCheckIn; at?: string }
  | { type: "LOAD_PLAN_DRAFT"; plan: WorkoutPlan; checkIn?: DailyCheckIn; source: "ai" | "user" | "template"; message?: string; at?: string }
  | { type: "ACCEPT_PLAN"; at?: string }
  | { type: "REJECT_PLAN"; at?: string }
  | { type: "SET_FINISHED"; record: Omit<SetRecord, "setIndex" | "plannedSetIndex">; at?: string }
  | { type: "UPDATE_PENDING_SET"; record: Partial<Omit<SetRecord, "setIndex" | "plannedSetIndex">>; at?: string }
  | { type: "SUBMIT_FEEDBACK"; kind?: FeedbackKind; kinds?: FeedbackKind[]; message?: string; messages?: string[]; at?: string }
  | { type: "SUBMIT_TRANSITION_FEEDBACK"; kind: FeedbackKind; message?: string; at?: string }
  | { type: "REST_FINISHED"; at?: string }
  | { type: "REST_EXTENDED"; seconds: number; at?: string }
  | { type: "EMERGENCY_STOP"; message?: string; at?: string }
  | { type: "CONFIRM_SUMMARY"; at?: string }
  | { type: "RECORD_AI_AUDIT"; audit: Omit<AiSuggestionAudit, "id" | "at">; at?: string }
  | { type: "CANCEL"; at?: string };

export interface ProgressSnapshot {
  completedMainSets: number;
  handledMainSets: number;
  totalMainSets: number;
  percentComplete: number;
}
