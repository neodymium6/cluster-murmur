defmodule ClusterMurmur.Repo.Migrations.AddIncompleteConversationIndex do
  use Ecto.Migration

  def change do
    drop index(:conversations, [:status, :started_at])

    create index(:conversations, [:started_at, :id],
             name: :conversations_incomplete_started_at_id_index,
             where: "status IN ('starting', 'generating', 'waiting')"
           )
  end
end
