/*
Copyright 2026 The llm-d Authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package worker

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	"github.com/llm-d/llm-d-batch-gateway/internal/processor/config"
	"github.com/llm-d/llm-d-batch-gateway/internal/processor/pipeline"
)

func testModelPlanCollision(t *testing.T, models []string) {
	t.Helper()
	root := t.TempDir()
	mapping := map[string]string{}
	used := map[string]int{}
	acc := newPlanAccumulator(root)
	var data []byte
	var offset int64
	for i, model := range models {
		line, err := json.Marshal(map[string]any{"custom_id": model, "method": "POST", "url": "/v1/chat/completions", "body": map[string]any{"model": model, "messages": []any{}}})
		if err != nil {
			t.Fatal(err)
		}
		line = append(line, '\n')
		offset = accumulatePlanEntry(acc, model, mapping, used, offset, uint32(len(line)), uint32(i))
		data = append(data, line...)
	}
	t.Logf("model mapping=%v", mapping)
	safeIDs := []string{}
	for _, s := range mapping {
		safeIDs = append(safeIDs, s)
	}
	if err := acc.Finalize(safeIDs); err != nil {
		t.Fatal(err)
	}
	if err := writeModelMappings(root, mapping, int64(len(models)), 0); err != nil {
		t.Fatal(err)
	}
	mm, err := readModelMap(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("reverse mapping=%v", mm.SafeToModel)
	path := filepath.Join(root, "input.jsonl")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	src := NewPlanFileSource(PlanFileSourceConfig{InputFile: f, PlansDir: filepath.Join(root, "plans"), ModelMap: mm, Cfg: config.NewConfig(), Logger: logr.Discard()})
	ch := make(chan pipeline.RequestItem, len(models))
	if err := src.Produce(context.Background(), ch); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for item := range ch {
		if seen[item.CustomID] {
			t.Errorf("duplicate request %q", item.CustomID)
		}
		seen[item.CustomID] = true
		bodyModel := item.Body["model"]
		t.Logf("custom_id=%s routed_model=%s body_model=%s", item.CustomID, item.ModelID, bodyModel)
		if item.ModelID != bodyModel {
			t.Errorf("request routed to wrong model gateway: route=%s body=%s", item.ModelID, bodyModel)
		}
	}
	if len(seen) != len(models) {
		t.Errorf("got %d requests, want %d", len(seen), len(models))
	}
}

func TestModelPlanCollisionPreservesRouting(t *testing.T) {
	cases := [][]string{
		{"org/model", "org_model", "org_model_2"},
		{"org_model_2", "org/model", "org_model"},
		{"org/model", "org_model_2", "org_model"},
		{"org_model", "org/model", "org_model_2"},
		{"org_model", "org_model_2", "org/model"},
		{"org_model_2", "org_model", "org/model"},
		{"org_model_2", "org_model_3", "org/model", "org_model", "org:model", "org_model_2_2"},
	}
	for _, models := range cases {
		t.Run(models[0]+"/"+models[1], func(t *testing.T) { testModelPlanCollision(t, models) })
	}
}
