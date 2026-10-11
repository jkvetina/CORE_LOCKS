--
-- The application the apex suite locks: two empty pages and nothing else.
-- Installed by install_apex.sql, which sets the workspace, the id and the schema.
--
set define off verify off feedback off
whenever sqlerror exit failure rollback

begin
wwv_flow_imp.import_begin (
 p_version_yyyy_mm_dd=>'2026.03.30'
,p_release=>'26.1.0'
,p_default_workspace_id=>wwv_flow_application_install.get_workspace_id
,p_default_application_id=>9901
,p_default_id_offset=>0
,p_default_owner=>'CORE_LOCKS'
);
end;
/

begin
wwv_flow_imp.remove_flow(wwv_flow.g_flow_id);
end;
/

begin
wwv_imp_workspace.create_flow(
 p_id=>wwv_flow.g_flow_id
,p_owner=>nvl(wwv_flow_application_install.get_schema,'CORE_LOCKS')
,p_name=>'CORE_LOCKS test fixture'
,p_alias=>'CLUT'
,p_flow_language=>'en'
,p_flow_language_derived_from=>'FLOW_PRIMARY_LANGUAGE'
,p_flow_version=>'Release 1.0'
,p_flow_status=>'AVAILABLE_W_EDIT_LINK'
,p_authorize_batch_job=>'N'
,p_rejoin_existing_sessions=>'N'
,p_file_storage=>'DB'
,p_is_pwa=>'N'
);
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>1
,p_name=>'First'
,p_alias=>'FIRST'
,p_step_title=>'First'
,p_autocomplete_on_off=>'OFF'
);
end;
/

begin
wwv_flow_imp_page.create_page(
 p_id=>2
,p_name=>'Second'
,p_alias=>'SECOND'
,p_step_title=>'Second'
,p_autocomplete_on_off=>'OFF'
);
end;
/

begin
wwv_flow_imp.import_end(p_auto_install_sup_obj => false);
commit;
end;
/

set verify on feedback on define on
