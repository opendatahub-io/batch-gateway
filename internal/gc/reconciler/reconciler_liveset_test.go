package reconciler

import (
	"context"
	"testing"

	"github.com/llm-d/llm-d-batch-gateway/internal/database/mock"
	"github.com/llm-d/llm-d-batch-gateway/internal/shared/openai"
)

func TestReconcilerWithoutLiveSnapshot(t *testing.T) {
	t.Run("owned jobs are left alone until the pod watcher has reported", func(t *testing.T) {
		ctx := context.Background()
		batchDB := newMockBatchDB()
		queue := mock.NewMockBatchPriorityQueueClient()

		storeItems(t, batchDB,
			newTestBatchItem("owned-valid", "processor-0", openai.BatchStatusInProgress, futureSLO()),
			newTestBatchItem("owned-expired", "processor-1", openai.BatchStatusInProgress, expiredSLO()),
		)

		r, resultCh := newTestReconciler(t, batchDB, queue)
		// Simulates the periodic tick firing before SetLiveProcessors was ever called.
		r.run(ctx)

		result := <-resultCh
		if result.ReEnqueued != 0 || result.Expired != 0 {
			t.Errorf("reconciler acted with no live snapshot: reEnqueued=%d expired=%d", result.ReEnqueued, result.Expired)
		}
		ids, err := queue.PQGetIDs(ctx)
		if err != nil {
			t.Fatalf("PQGetIDs: %v", err)
		}
		if ids["owned-valid"] {
			t.Errorf("owned-valid was re-enqueued away from a processor that was never observed dead")
		}
		assertJobStatus(t, batchDB, "owned-expired", openai.BatchStatusInProgress)
	})
}
