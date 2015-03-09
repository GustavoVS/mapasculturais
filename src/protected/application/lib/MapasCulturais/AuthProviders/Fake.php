<?php
namespace MapasCulturais\AuthProviders;

use MapasCulturais\App;

class Fake extends \MapasCulturais\AuthProvider{
    protected function _init() {
        $app = App::i();

        // add actions to auth controller
        $app->hook('GET(auth.index)', function (\MapasCulturais\Controller $controller) use($app){
            $users = $app->repo('User')->findBy(array(), array('id' => 'ASC'));

            $controller->render('fake-authentication', array('users' => $users, 'form_action' => $app->createUrl('auth', 'fakeLogin')));
        });

        $app->hook('GET(auth.fakeLogin)', function (\MapasCulturais\Controller $controller) use($app){
            $app->auth->processResponse();

            if($app->auth->isUserAuthenticated()){
                $app->redirect ($app->auth->getRedirectPath());
            }else{
                $app->redirect ($controller->createUrl(''));
            }
        });
    }

    public function _cleanUserSession() {
        unset($_SESSION['auth.fakeAuthenticationUserId']);
    }

    /**
     * Returns the URL to redirect after authentication
     * @return string
     */
    public function getRedirectPath(){
        $path = key_exists('mapasculturais.auth.redirect_path', $_SESSION) ?
                    $_SESSION['mapasculturais.auth.redirect_path'] : App::i()->createUrl('site','');

        unset($_SESSION['mapasculturais.auth.redirect_path']);

        return $path;
    }


    public function _getAuthenticatedUser() {
        $user = null;
        if(key_exists('auth.fakeAuthenticationUserId', $_SESSION)){
            $user_id = $_SESSION['auth.fakeAuthenticationUserId'];
            $user = App::i()->repo("User")->find($user_id);
            return $user;
        }else{
            return null;
        }
    }


    /**
     * Process the Opauth authentication response and creates the user if it not exists
     * @return boolean true if the response is valid or false if the response is not valid
     */
    public function processResponse(){
        if(key_exists('fake_authentication_user_id', $_GET)){
            $_SESSION['auth.fakeAuthenticationUserId'] = $_GET['fake_authentication_user_id'];
            $this->_setAuthenticatedUser($this->_getAuthenticatedUser());
            App::i()->applyHook('auth.successful');
        }
    }

    protected function _createUser($data) {
        $app = App::i();
        $u = new \MapasCulturais\Entities\User;

        $u->authProvider = 'Fake';
        $u->authUid = uniqid('fake-');
        $u->email = $data['email'];

        $app->em->persist($u);
        $app->em->flush();

        $a = new \MapasCulturais\Entities\Agent;
        $a->user = $u;
        $a->name = $data['name'];

        $app->em->persist($a);
        $app->em->flush();

        $u->profile = $a;
        $u->save(true);

    }
}