defmodule ClusterMurmur.Repo.Migrations.AddEventDedupeMarkerPruneIndex do
  use Ecto.Migration

  def up do
    drop index(:event_dedupe_markers, [:accepted_at])
    create index(:event_dedupe_markers, [:accepted_at, :dedupe_key])
  end

  def down do
    drop index(:event_dedupe_markers, [:accepted_at, :dedupe_key])
    create index(:event_dedupe_markers, [:accepted_at])
  end
end
