# Fronteiras de integração do Desk

## Autoridade e origem

Uma configuração local organiza projetos; não concede autorização remota. O MCP legado oferece descoberta e memória compartilhada sem isolamento verificável, portanto o Desk não transforma títulos ou parâmetros ignorados em filtros de segurança.

O adapter usa `m3.platform.v1`: capabilities, principal autenticado, registry, busca e checkpoint por projeto, criação idempotente de runs, leitura individual, cancelamento, retomada e eventos incrementais. O servidor continua sendo a autoridade de acesso. O prazo local de cinco minutos é uma janela conservadora de revalidação do cliente, não uma credencial emitida pelo servidor.

Toda resposta de sucesso em uma rota autorizada deve trazer `authorized_context` com principal, tenant e projeto iguais aos da requisição. A troca de conta, projeto ou conexão invalida respostas atrasadas. Runs e eventos permanecem estritamente no contexto selecionado.

Com `document_sharing=true`, memórias possuem origem preservada (`tenant_id`, `project_id` e `origin`) e `access` vinculado ao principal. Uma memória de outra origem só é aceita com `explicit_grant` e `read_only=true`. Isso não concede acesso ao registry, às execuções ou aos outros documentos da origem. Revogação é observada na próxima leitura autorizada; o Desk não alega notificação instantânea de revogação.

## Persistência

O cache separa origem normalizada da API, principal, tenant, projeto e subprojeto. A origem evita colisões quando teste e produção usam os mesmos IDs. Dados antigos sem origem não são promovidos automaticamente a um novo backend. A migração de UserDefaults por nome é limitada ao namespace local legado; recibos de migração evitam reaplicação e os originais são mantidos.

Apenas rascunhos locais, seleção, cursores e hashes/chaves de operações pendentes persistem. Conteúdo remoto não fica no disco. Queda, negação, mudança de contexto ou expiração limpa as visualizações remotas. Uma adoção explícita pode copiar checkpoint para o rascunho; esse conteúdo passa a ser uma cópia local do usuário.

O cursor é salvo antes de apresentar novos eventos. Na retomada o snapshot atual do run é consultado e eventos posteriores ao cursor são recuperados. A lista de eventos da sessão tem limite de 500; o histórico completo continua sob responsabilidade do backend.

## Execução

Preparar, copiar ou exportar handoff não envia uma mensagem para outro chat. O endpoint atual de criação recebe somente `objective` e `provider` escolhido explicitamente entre os executores anunciados, mesmo quando o rascunho tem contexto, fontes e bloqueios. A interface informa essa limitação.

Registrar um run não prova execução de agente de IA. `agent_execution` e disponibilidade de registro são tratados separadamente. A 0.2.0 foi validada com agente de IA desabilitado. A 0.2.1 consome `execution_providers`: `local`/`docker-tool` é a ferramenta fixa; `local-model`/`text-model` é o modelo textual local experimental. Cada tipo requer seu flag correspondente (`tool_execution` ou `agent_execution`). Providers ausentes, desabilitados ou de tipo desconhecido não podem ser criados/retomados. Não existe fallback automático de executor. O provider salvo no run, e não a capability global atual, define o rótulo do histórico.

A escolha de provider pertence ao rascunho com namespace e precisa ser explícita; drafts anteriores sem esse campo exigem escolha. O hash da criação inclui objetivo e provider, separando tentativas iguais direcionadas a executores diferentes. Trocar de provider não reconcilia uma tentativa anterior incerta: a chave anterior permanece disponível quando se repete o objetivo/provider originais.

Resultados e checkpoints textuais são exibidos como dados literais, com modelo informado pelo próprio resultado. A API transmite somente o objetivo atual; contexto, fontes, delta e histórico do handoff não são enviados. Modelo/digest/URL são configurações do backend, não parâmetros controlados pelo run. O modelo experimental validado não tem ferramentas; não se infere autonomia de shell/MCP, qualidade geral ou aborto imediato do motor.

Criação e retomada gravam a chave de idempotência antes do envio e a removem após confirmação. Falha ou timeout mantém a tentativa recuperável; repetir a operação equivalente reutiliza sua chave. Reconexão automática revalida acesso, mas não reproduz mutações. Estados de runs são mesclados por versão para não regredir com respostas atrasadas.

## Transporte

O cliente MCP negocia versão, envia a notificação de inicialização e descobre ferramentas paginadas. O transporte suporta JSON e SSE incremental, valida IDs, trata timeouts/cancelamento e não reproduz mutações ao recuperar uma sessão. A allowlist de leitura exige que a ferramenta também tenha sido anunciada.

Referências primárias:
- https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

O cliente HTTP da plataforma valida endpoints HTTPS/loopback, rejeita redirects e faz retries limitados somente para leituras elegíveis. Tokens ficam no Keychain ou são lidos de um arquivo protegido no modo de verificação, nunca no cache ou nos logs.

## Limites desta entrega

O backend testado é um serviço local de sessão. Esta entrega não instala o backend no NAS, não configura túnel ou autostart, não migra a memória pessoal legada e não faz rollout de produção. Fixtures e renders validam implementação/apresentação; não equivalem a aprovação visual do usuário ou benchmark completo do corpus.
