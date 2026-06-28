import type { AiFeedbackOption, AiPlanDraft, DailyCheckIn, EquipmentInventory, UserProfile, WorkoutEvent, WorkoutSession } from "@fox/core";

const apiBase = import.meta.env.VITE_FOX_API_URL ?? "http://localhost:4177";

interface SessionResponse {
  session: WorkoutSession;
}

interface FeedbackOptionsResponse extends SessionResponse {
  options: AiFeedbackOption[];
}

interface PlanDraftResponse extends SessionResponse {
  draft: AiPlanDraft;
}

interface EquipmentResponse {
  equipmentInventory: EquipmentInventory;
}

interface UserProfileResponse {
  userProfile: UserProfile | null;
}

export interface EntryRecord {
  id: string;
  title: string;
  occurredAt: string;
  payload: Record<string, unknown>;
}

interface EntriesResponse {
  entries: EntryRecord[];
}

interface EntryResponse {
  entry: EntryRecord;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${apiBase}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...init?.headers
    }
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `Fox API request failed with ${response.status}`);
  }

  return (await response.json()) as T;
}

export const foxApi = {
  async getCurrentSession(): Promise<WorkoutSession> {
    const payload = await request<SessionResponse>("/sessions/current");
    return payload.session;
  },

  async createSession(): Promise<WorkoutSession> {
    const payload = await request<SessionResponse>("/sessions", { method: "POST", body: "{}" });
    return payload.session;
  },

  async dispatchEvent(event: WorkoutEvent): Promise<WorkoutSession> {
    const payload = await request<SessionResponse>("/sessions/current/events", {
      method: "POST",
      body: JSON.stringify(event)
    });
    return payload.session;
  },

  async getFeedbackOptions(): Promise<FeedbackOptionsResponse> {
    return request<FeedbackOptionsResponse>("/sessions/current/ai/feedback-options");
  },

  async draftPlan(checkIn: DailyCheckIn): Promise<PlanDraftResponse> {
    return request<PlanDraftResponse>("/sessions/current/ai/plan-draft", {
      method: "POST",
      body: JSON.stringify({ checkIn })
    });
  },

  async getEquipmentInventory(): Promise<EquipmentInventory> {
    const payload = await request<EquipmentResponse>("/profile/equipment");
    return payload.equipmentInventory;
  },

  async saveEquipmentInventory(equipmentInventory: EquipmentInventory): Promise<EquipmentInventory> {
    const payload = await request<EquipmentResponse>("/profile/equipment", {
      method: "PATCH",
      body: JSON.stringify({ equipmentInventory })
    });
    return payload.equipmentInventory;
  },

  async getUserProfile(): Promise<UserProfile | null> {
    const payload = await request<UserProfileResponse>("/profile/user");
    return payload.userProfile;
  },

  async saveUserProfile(userProfile: UserProfile): Promise<UserProfile> {
    const payload = await request<UserProfileResponse>("/profile/user", {
      method: "PATCH",
      body: JSON.stringify({ userProfile })
    });
    if (!payload.userProfile) {
      throw new Error("Fox API did not return a user profile");
    }
    return payload.userProfile;
  },

  async listEntries(): Promise<EntryRecord[]> {
    const payload = await request<EntriesResponse>("/entries");
    return payload.entries;
  },

  async updateEntryNote(entryId: string, userNote: string): Promise<EntryRecord> {
    const payload = await request<EntryResponse>(`/entries/${entryId}`, {
      method: "PATCH",
      body: JSON.stringify({ userNote })
    });
    return payload.entry;
  }
};
