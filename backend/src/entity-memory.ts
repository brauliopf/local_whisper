import { ProviderFailureError } from "./errors.js";
import type { ConversationStore, EntityMemoryRecord } from "./memory.js";
import {
  entityEmbeddingDimensions,
  type EntityMemoryProvider,
  type ExtractedEntity,
} from "./provider.js";

export const defaultAccountId = "00000000-0000-4000-8000-000000000001";

const credentialPattern = /\b(?:password|passcode|api[_\s-]?key|access[_\s-]?token|secret)\s*(?:is|:|=)\s*\S+|\bBearer\s+[A-Za-z0-9._~+/=-]+|\b(?:sk(?:-[A-Za-z0-9_-]{8,}|_(?:live|test)_[A-Za-z0-9_-]{8,})|rk_(?:live|test)_[A-Za-z0-9_-]{8,}|sb_(?:secret|publishable)_[A-Za-z0-9_-]{8,}|gh[opsu]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AIza[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16})|-----BEGIN [A-Z ]*PRIVATE KEY-----/i;

function includesName(evidence: string, name: string): boolean {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(?<![\\p{L}\\p{N}])${escapedName}(?![\\p{L}\\p{N}])`, "iu").test(evidence);
}

function hasContext(evidence: string, name: string): boolean {
  const nameWords: string[] = name.toLocaleLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
  const evidenceWords: string[] = evidence.toLocaleLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
  return evidenceWords.some((word) => !nameWords.includes(word));
}

function groundedEvidence(text: string, entity: ExtractedEntity): string | undefined {
  const name = entity.name.trim();
  const evidence = entity.evidence.trim();
  if (
    !name ||
    name.length > 120 ||
    !evidence ||
    evidence.length > 2_000 ||
    !text.includes(evidence) ||
    !includesName(evidence, name) ||
    !hasContext(evidence, name) ||
    credentialPattern.test(evidence)
  ) {
    return undefined;
  }
  return evidence;
}

export class EntityMemoryService {
  constructor(
    private readonly provider: Pick<EntityMemoryProvider, "extractEntities" | "embedTexts">,
    private readonly store: Pick<ConversationStore, "appendEntities">,
  ) {}

  async recordTurn(text: string, signal: AbortSignal): Promise<void> {
    const entities = (await this.provider.extractEntities(text, signal))
      .flatMap((entity) => {
        const evidence = groundedEvidence(text, entity);
        return evidence
          ? [{ name: entity.name.trim(), type: entity.type, description: evidence }]
          : [];
      });
    if (entities.length === 0) return;

    const embeddingInputs = entities.map(
      ({ name, type, description }) => `${name} (${type}): ${description}`,
    );
    const embeddings = await this.provider.embedTexts(embeddingInputs, signal);
    if (
      embeddings.length !== entities.length ||
      embeddings.some((embedding) =>
        embedding.length !== entityEmbeddingDimensions ||
        embedding.some((value) => !Number.isFinite(value))
      )
    ) {
      throw new ProviderFailureError();
    }

    const records: EntityMemoryRecord[] = entities.map((entity, index) => ({
      ...entity,
      embedding: embeddings[index]!,
    }));
    await this.store.appendEntities(defaultAccountId, records, signal);
  }
}
