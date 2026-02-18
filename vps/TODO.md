1. Créer une app java démo pour déploiement local + vps via helm 

Pour un usage en équipe, voir pour :

1. Ajouter wireguard pour un accès web aux svc accessibles seulement en port-forward (grafana, prome & keycloak/admin)
   sur le VPS (voir Wireguard)
   -> Accès aux services via IP interne du cluster ;

2. Ajouter un Vault pour ne plus faire usage de SealedSecret pour déployer l'app cible : Nécessaire pour un travail en
   équipe

   