create database pseudo_gtid;
 
 CREATE DEFINER=`root`@`localhost` EVENT `update_pseudo_gtid_rbr_event` ON SCHEDULE EVERY 1 SECOND STARTS now() ON COMPLETION PRESERVE ENABLE DO begin
		set @uuid:=(select variable_value from information_schema.global_status where variable_name='wsrep_cluster_state_uuid');
		set @last_com:=(select variable_value from information_schema.global_status where variable_name='wsrep_last_committed');
		set @pseudo_gtid := (select concat_ws(':', @uuid, @last_com));
		set @_create_statement := concat('create or replace view pseudo_gtid.pseudo_gtid_v as select \'', @pseudo_gtid, '\' from dual');
      PREPARE st FROM @_create_statement;
      EXECUTE st;
      DEALLOCATE PREPARE st;
    end
