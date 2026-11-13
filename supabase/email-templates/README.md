# Modelos de e-mail do Vortex Food (português)

Estes arquivos são modelos HTML para os e-mails de autenticação e notificações de segurança do Supabase Auth. Eles usam variáveis oficiais do Supabase, como `{{ .ConfirmationURL }}`, `{{ .Email }}`, `{{ .NewEmail }}`, `{{ .OldEmail }}` e `{{ .Token }}`.

## Modelos incluídos

| Arquivo | Tipo no Supabase | Assunto sugerido |
|---|---|---|
| confirmation.html | Confirm signup | Confirme seu cadastro no Vortex Food |
| invite.html | Invite user | Você foi convidado para o Vortex Food |
| magic_link.html | Magic link | Seu link de acesso ao Vortex Food |
| email_change.html | Change email address | Confirme seu novo e-mail de acesso |
| recovery.html | Reset password | Redefinição de senha do Vortex Food |
| reauthentication.html | Reauthentication | Código de verificação do Vortex Food: {{ .Token }} |
| password_changed_notification.html | Password changed notification | Sua senha do Vortex Food foi alterada |
| email_changed_notification.html | Email changed notification | O e-mail da sua conta Vortex Food foi alterado |
| phone_changed_notification.html | Phone changed notification | Seu telefone de segurança foi alterado |
| identity_linked_notification.html | Identity linked notification | Um novo método de acesso foi vinculado |
| identity_unlinked_notification.html | Identity unlinked notification | Um método de acesso foi desvinculado |
| factor_enrolled_notification.html | Factor enrolled notification | Um método de verificação foi adicionado |
| factor_unenrolled_notification.html | Factor unenrolled notification | Um método de verificação foi removido |

## Aplicação no projeto Supabase hospedado

Os arquivos no GitHub **não alteram automaticamente** os modelos do projeto Supabase hospedado. Depois de revisar os modelos, copie o conteúdo de cada arquivo para o tipo correspondente em **Supabase Dashboard → Authentication → Email Templates** e configure os assuntos sugeridos. Ative também as notificações de alteração de senha e e-mail em Authentication → Notifications, quando disponíveis.

Configure um provedor SMTP próprio e verificado antes de liberar o envio para clientes e funcionários. O SMTP de teste padrão do Supabase tem restrições de destinatários e não é adequado para produção. Configure também o endereço remetente do Vortex Food, SPF, DKIM e DMARC no domínio de envio.

## Observações

- Não remova `{{ .ConfirmationURL }}` dos fluxos que usam link de confirmação.
- O modelo de alteração de e-mail usa `{{ .NewEmail }}`.
- A notificação de e-mail alterado usa `{{ .OldEmail }}` e `{{ .Email }}`.
- O modelo de reautenticação usa `{{ .Token }}`.
- Teste cada fluxo com contas de teste antes de ativar em produção.
- A entrega depende da configuração SMTP, reputação do domínio, limites do provedor e configurações de autenticação do Supabase.
