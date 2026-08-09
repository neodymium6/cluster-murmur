defmodule ClusterMurmur.Repo.Migrations.AddEventRetentionLookupIndexes do
  use Ecto.Migration

  def up do
    drop index(:events, [:occurred_at])
    create index(:events, [:occurred_at, :id])
    create index(:trigger_executions, [:event_id])
    create index(:event_dedupe_markers, [:event_id])
  end

  def down do
    drop index(:event_dedupe_markers, [:event_id])
    drop index(:trigger_executions, [:event_id])
    drop index(:events, [:occurred_at, :id])
    create index(:events, [:occurred_at])
  end
end
