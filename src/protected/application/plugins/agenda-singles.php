<?php

use MapasCulturais\App;

$app = App::i();

//mapas.local/agent/agendaSingle/id:56565/?from=
$app->hook('GET(<<agent|space|project>>.agendaSingle)', function($controller) use ($app) {
    $entity = $controller->requestedEntity;

    if(!$entity){
        $app->pass();
    }elseif(!isset($controller->getData['from']) || !isset($controller->getData['to'])){
        $app->stop();
    }

    $date_from = DateTime::createFromFormat('Y-m-d', $controller->getData['from']);
    $date_to =   DateTime::createFromFormat('Y-m-d', $controller->getData['to']);

    if(!$date_from || !$date_to){
        $app->stop();
    }

    if($entity->className ===  'MapasCulturais\Entities\Space'){

        $events = !$entity->id ? array() : $app->repo('Event')->findBySpace($entity, $date_from, $date_to);

    }elseif($entity->className ===  'MapasCulturais\Entities\Agent'){

        $events = !$entity->id ? array() : $app->repo('Event')->findByAgent($entity, $date_from, $date_to);

    }elseif($entity->className ===  'MapasCulturais\Entities\Project'){

        $events = !$entity->id ? array() : $app->repo('Event')->findByProject($entity, $date_from, $date_to);

    }else{
        $events = array();
    }

    if(empty($events)){
        $app->stop();
    }
    $app->view->part('agenda-content', array('events'=>$events, 'entity'=>$entity));
});

$app->hook('view.render(<<agent|space|project>>/<<single|edit>>):before', function() use ($app) {
    $app->view->enqueueScript('app', 'agenda-single', '/js/agenda-single.js', array('mapasculturais'));
});
