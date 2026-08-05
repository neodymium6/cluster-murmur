defmodule ClusterMurmur.Repo.Migrations.AddPersonaMessageHistoryIndex do
  use Ecto.Migration

  def change do
    create index(:messages, [:persona_id, :inserted_at, :id],
             name: :messages_published_persona_inserted_at_id_index,
             where: "NOT (discord_message_id IS NULL)"
           )
  end
end
